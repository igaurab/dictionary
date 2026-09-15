import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum BrowseIndexError: LocalizedError {
    case missingDictionary
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .missingDictionary:
            return "The dictionary file is missing. Try downloading it again."
        case .sqlite(let message):
            return "The word list could not be prepared (\(message))."
        }
    }
}

/// A dictionary's headwords in reading order, for leafing through from A to Z.
///
/// The dictionaries' own indexes sort by byte, which files "école" after
/// "zygote" and every French "dé-" word after "dz". A printed dictionary ignores
/// accents, so this builds a small companion database once per dictionary: real
/// entries only (no inflected forms), one row per headword, inserted in folded
/// order. Row ids then run 1...N in reading order, so any row of a two-million-
/// entry dictionary is one primary-key read away and the list only ever holds a
/// few pages of words in memory.
final class BrowseIndex: @unchecked Sendable {
    struct Section: Sendable {
        let title: String
        /// Zero-based position of the section's first word.
        let start: Int
        let count: Int
    }

    let wordCount: Int
    let sections: [Section]
    /// The letters down the side: `#` for numbers, then the dictionary's own
    /// alphabet. A stray Greek or IPA letter in a French dictionary still gets
    /// a section, but not a place in the index.
    let indexTitles: [(title: String, section: Int)]

    private let db: OpaquePointer
    private let sourceSignature: String
    /// Pages of words keyed by page number. The table view asks for rows on the
    /// main thread, but the lock keeps this honest if that ever changes.
    private var pages: [Int: [String]] = [:]
    private let lock = NSLock()

    private static let pageSize = 200
    private static let maxCachedPages = 30
    /// Bump when the build changes what goes in, so old indexes are rebuilt.
    private static let formatVersion = "1"

    // MARK: - Opening

    /// Opens an index built earlier, or returns nil when there is none or it
    /// was built from a different copy of the dictionary.
    init?(url: URL, source: URL) {
        guard FileManager.default.fileExists(atPath: url.path),
              let signature = Self.signature(of: source) else { return nil }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }

        var meta: [String: String] = [:]
        Self.query(handle, "SELECT key, value FROM meta") { statement in
            meta[Self.text(statement, 0)] = Self.text(statement, 1)
        }
        guard meta["format"] == Self.formatVersion, meta["source"] == signature else {
            sqlite3_close(handle)
            return nil
        }

        var sections: [Section] = []
        Self.query(handle, "SELECT initial, first, n FROM sections ORDER BY first") { statement in
            let title = Self.sectionTitle(forInitial: Self.text(statement, 0))
            let start = Int(sqlite3_column_int64(statement, 1)) - 1
            let count = Int(sqlite3_column_int64(statement, 2))
            // Numbers and the empty key are both "#" and sort next to each other.
            if let last = sections.last, last.title == title, last.start + last.count == start {
                sections[sections.count - 1] = Section(title: title, start: last.start,
                                                       count: last.count + count)
            } else {
                sections.append(Section(title: title, start: start, count: count))
            }
        }
        guard !sections.isEmpty else {
            sqlite3_close(handle)
            return nil
        }

        self.db = handle
        self.sourceSignature = signature
        self.sections = sections
        self.wordCount = sections.reduce(0) { $0 + $1.count }
        self.indexTitles = Self.indexTitles(for: sections)
    }

    deinit {
        sqlite3_close(db)
    }

    /// False once the dictionary file has been replaced, by a re-download say.
    func isCurrent(for source: URL) -> Bool {
        Self.signature(of: source) == sourceSignature
    }

    // MARK: - Reading

    /// The headword at a zero-based position in reading order.
    func word(at position: Int) -> String {
        let page = position / Self.pageSize
        lock.lock()
        defer { lock.unlock() }

        let words: [String]
        if let cached = pages[page] {
            words = cached
        } else {
            if pages.count >= Self.maxCachedPages,
               let farthest = pages.keys.max(by: { abs($0 - page) < abs($1 - page) }) {
                pages[farthest] = nil
            }
            words = loadPage(page)
            pages[page] = words
        }
        let offset = position - page * Self.pageSize
        return words.indices.contains(offset) ? words[offset] : ""
    }

    private func loadPage(_ page: Int) -> [String] {
        var words: [String] = []
        words.reserveCapacity(Self.pageSize)
        let sql = "SELECT word FROM words WHERE rowid > \(page * Self.pageSize) ORDER BY rowid LIMIT \(Self.pageSize)"
        Self.query(db, sql) { statement in
            words.append(Self.text(statement, 0))
        }
        return words
    }

    // MARK: - Building

    /// Reads every headword out of `source` and writes the index to
    /// `destination`. Takes a second for WordNet and several for the two
    /// million rows of the French Wiktionary, so call it off the main thread.
    static func build(_ lexicon: Lexicon, from source: URL, to destination: URL,
                      progress: (Double) -> Void) throws {
        guard let signature = signature(of: source) else { throw BrowseIndexError.missingDictionary }

        var sourceHandle: OpaquePointer?
        guard sqlite3_open_v2(source.path, &sourceHandle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let sourceDB = sourceHandle else {
            sqlite3_close(sourceHandle)
            throw BrowseIndexError.missingDictionary
        }
        defer { sqlite3_close(sourceDB) }

        let table: String
        let selectSQL: String
        switch lexicon {
        case .wordNet:
            table = "words"
            selectSQL = "SELECT id, word, word_lower, NULL FROM words"
        case .installed:
            table = "entries"
            selectSQL = "SELECT id, word, word_lower, definition FROM entries"
        }
        var lastRowID: Int64 = 1
        query(sourceDB, "SELECT max(rowid) FROM \(table)") { lastRowID = max(1, sqlite3_column_int64($0, 0)) }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("partial")
        try? fileManager.removeItem(at: partial)

        var outputHandle: OpaquePointer?
        guard sqlite3_open_v2(partial.path, &outputHandle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db = outputHandle else {
            sqlite3_close(outputHandle)
            throw BrowseIndexError.sqlite("could not create the index file")
        }
        var closed = false
        defer {
            if !closed { sqlite3_close(db) }
            try? fileManager.removeItem(at: partial)
        }

        // Nothing here needs to survive a crash: a half-built index is simply
        // deleted and built again, so skip the journal.
        try execute(db, """
            PRAGMA journal_mode = OFF;
            PRAGMA synchronous = OFF;
            PRAGMA temp_store = FILE;
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TEMP TABLE staging(key TEXT NOT NULL, lower TEXT NOT NULL, word TEXT NOT NULL);
            BEGIN;
            """)

        var select: OpaquePointer?
        var insert: OpaquePointer?
        defer {
            sqlite3_finalize(select)
            sqlite3_finalize(insert)
        }
        guard sqlite3_prepare_v2(sourceDB, selectSQL, -1, &select, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "INSERT INTO staging(key, lower, word) VALUES(?, ?, ?)",
                                 -1, &insert, nil) == SQLITE_OK else {
            throw BrowseIndexError.sqlite(String(cString: sqlite3_errmsg(db)))
        }

        var scanned = 0
        while sqlite3_step(select) == SQLITE_ROW {
            scanned += 1
            if scanned % 20_000 == 0 {
                progress(0.85 * Double(sqlite3_column_int64(select, 0)) / Double(lastRowID))
            }
            if let definition = sqlite3_column_text(select, 3),
               EntryText.isInflectionOnly(definition, count: Int(sqlite3_column_bytes(select, 3))) {
                continue
            }
            guard let word = sqlite3_column_text(select, 1),
                  let lower = sqlite3_column_text(select, 2) else { continue }

            let key = sortKey(String(cString: lower))
            sqlite3_bind_text(insert, 1, key, -1, SQLITE_TRANSIENT)
            // Copied straight from the source row, without a Swift string.
            sqlite3_bind_text(insert, 2, UnsafeRawPointer(lower).assumingMemoryBound(to: CChar.self),
                              sqlite3_column_bytes(select, 2), SQLITE_TRANSIENT)
            sqlite3_bind_text(insert, 3, UnsafeRawPointer(word).assumingMemoryBound(to: CChar.self),
                              sqlite3_column_bytes(select, 1), SQLITE_TRANSIENT)
            guard sqlite3_step(insert) == SQLITE_DONE else {
                throw BrowseIndexError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_reset(insert)
        }
        progress(0.9)

        // Inserting in sorted order is what makes rowid the reading position.
        // "Porte" and "porte" share a row; max() keeps the lowercase spelling.
        try execute(db, """
            CREATE TABLE words(word TEXT NOT NULL, initial TEXT NOT NULL);
            INSERT INTO words(word, initial)
                SELECT max(word), substr(key, 1, 1) FROM staging
                GROUP BY key, lower ORDER BY key, lower;
            CREATE TABLE sections AS
                SELECT initial, min(rowid) AS first, count(*) AS n FROM words GROUP BY initial;
            DROP TABLE staging;
            """)

        let meta = [("format", formatVersion), ("source", signature), ("name", lexicon.name)]
        for (key, value) in meta {
            try execute(db, "INSERT INTO meta(key, value) VALUES('\(key)', '\(value.replacingOccurrences(of: "'", with: "''"))')")
        }
        try execute(db, "COMMIT")
        sqlite3_close(db)
        closed = true

        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: partial, to: destination)
        progress(1)
    }

    /// The order a printed dictionary uses: accents ignored ("é" files under
    /// "e", "ß" as "ss"), spaces and punctuation skipped so "a cappella" sits
    /// between "acanthus" and "accede", and "ñ" kept as its own letter after
    /// "n", the way Spanish dictionaries order it. Devanagari is already in
    /// dictionary order by code point, vowel signs and virama included, so its
    /// marks are left alone.
    static func sortKey(_ lower: String) -> String {
        if lower.utf8.allSatisfy({ (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) }) {
            return lower
        }
        var key = String.UnicodeScalarView()
        for scalar in lower.decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.value {
            case 0x0303 where key.last == "n":
                key.append("{") // sorts straight after "z"
            case 0x0300...0x036F:
                continue
            case 0x00DF:
                key.append(contentsOf: "ss".unicodeScalars)
            case 0x0153:
                key.append(contentsOf: "oe".unicodeScalars)
            case 0x00E6:
                key.append(contentsOf: "ae".unicodeScalars)
            default:
                switch scalar.properties.generalCategory {
                case .spaceSeparator, .lineSeparator, .paragraphSeparator, .control, .format,
                     .connectorPunctuation, .dashPunctuation, .openPunctuation,
                     .closePunctuation, .initialPunctuation, .finalPunctuation,
                     .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol,
                     .otherSymbol:
                    continue
                default:
                    key.append(scalar)
                }
            }
        }
        return String(key)
    }

    // MARK: - Sections

    private static func sectionTitle(forInitial initial: String) -> String {
        guard let scalar = initial.unicodeScalars.first, scalar.properties.numericType == nil else {
            return "#"
        }
        return initial.uppercased()
    }

    /// `#` plus the letters in the same Unicode block as the biggest section,
    /// which is the dictionary's own alphabet.
    private static func indexTitles(for sections: [Section]) -> [(title: String, section: Int)] {
        guard let largest = sections.filter({ $0.title != "#" }).max(by: { $0.count < $1.count }),
              let block = largest.title.unicodeScalars.first.map({ $0.value >> 7 }) else {
            return sections.isEmpty ? [] : [("#", 0)]
        }
        var titles: [(title: String, section: Int)] = []
        var seen = Set<String>()
        for (offset, section) in sections.enumerated() {
            let belongs = section.title == "#"
                || section.title.unicodeScalars.first.map({ $0.value >> 7 == block }) == true
            if belongs, seen.insert(section.title).inserted {
                titles.append((section.title, offset))
            }
        }
        return titles
    }

    // MARK: - SQLite

    /// Size and modification date: cheap to read, and both change when a
    /// dictionary is downloaded again.
    private static func signature(of url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(size.int64Value)-\(Int64(modified.timeIntervalSince1970))"
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw BrowseIndexError.sqlite(message)
        }
    }

    private static func query(_ db: OpaquePointer, _ sql: String, row: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        while sqlite3_step(statement) == SQLITE_ROW {
            row(statement)
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}

/// Opens and builds browse indexes, one at a time per dictionary, and keeps
/// the open ones for the life of the app.
@MainActor
final class BrowseIndexStore: ObservableObject {
    static let shared = BrowseIndexStore()

    /// 0...1 per lexicon id while its index is being built.
    @Published private(set) var progress: [String: Double] = [:]

    private var open: [String: BrowseIndex] = [:]
    private var builds: [String: Task<BrowseIndex, Error>] = [:]

    private static var directory: URL {
        DictionaryLibrary.storageDirectory.appendingPathComponent("Browse", isDirectory: true)
    }

    private static func fileURL(forLexiconID id: String) -> URL {
        directory.appendingPathComponent(id + ".browse.sqlite")
    }

    func index(for lexicon: Lexicon) async throws -> BrowseIndex {
        guard let source = lexicon.fileURL else { throw BrowseIndexError.missingDictionary }
        let id = lexicon.id
        if let cached = open[id], cached.isCurrent(for: source) { return cached }
        if let running = builds[id] { return try await running.value }

        let destination = Self.fileURL(forLexiconID: id)
        let report: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in
                let store = BrowseIndexStore.shared
                // A late report must not resurrect a finished build's bar.
                if store.builds[id] != nil { store.progress[id] = fraction }
            }
        }
        let task = Task.detached(priority: .userInitiated) { () throws -> BrowseIndex in
            if let existing = BrowseIndex(url: destination, source: source) {
                return existing
            }
            try BrowseIndex.build(lexicon, from: source, to: destination, progress: report)
            guard let built = BrowseIndex(url: destination, source: source) else {
                throw BrowseIndexError.sqlite("the new index could not be opened")
            }
            return built
        }
        builds[id] = task
        defer {
            builds[id] = nil
            progress[id] = nil
        }
        let index = try await task.value
        open[id] = index
        return index
    }

    /// Drops a dictionary's index when the dictionary itself goes away.
    func discardIndex(forLexiconID id: String) {
        open[id] = nil
        try? FileManager.default.removeItem(at: Self.fileURL(forLexiconID: id))
    }
}
