import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum StarDictImportError: LocalizedError {
    case unreadableSource
    case unsupportedSource(String)
    case unreadableArchive
    case missingInfoFile
    case missingIndexFile
    case missingDictionaryFile
    case malformedInfoFile
    case malformedIndex
    case decompressionFailed
    case emptyDictionary
    case databaseWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableSource:
            return "That file or folder could not be opened."
        case .unsupportedSource(let ext):
            let name = ext.isEmpty ? "file" : ".\(ext) file"
            return "This \(name) isn't a StarDict dictionary. Choose a .zip, "
                + "or a folder containing the .ifo, .idx and .dict files."
        case .unreadableArchive:
            return "That ZIP archive could not be read. If it is a .tar.gz or .tar.bz2, "
                + "unpack it first and choose the resulting folder."
        case .missingInfoFile:
            return "No .ifo file was found. A StarDict dictionary needs .ifo, .idx and .dict files."
        case .missingIndexFile:
            return "The .idx index file is missing."
        case .missingDictionaryFile:
            return "The .dict definition file is missing."
        case .malformedInfoFile:
            return "The .ifo file is not a valid StarDict info file."
        case .malformedIndex:
            return "The .idx index file is damaged and could not be read."
        case .decompressionFailed:
            return "A compressed file in this dictionary could not be decompressed."
        case .emptyDictionary:
            return "This dictionary contains no usable entries."
        case .databaseWriteFailed(let detail):
            return "The dictionary could not be saved (\(detail))."
        }
    }
}

/// Converts a StarDict dictionary into a single SQLite file the app can open
/// read-only, the same shape as the bundled WordNet database.
///
/// Everything here parses user-supplied files, so every read is bounds-checked
/// and a damaged file throws instead of trapping.
struct StarDictImporter {

    /// `source` may be a folder holding the `.ifo`/`.idx`/`.dict` set, a `.zip`
    /// of such a folder, or the `.ifo` file itself.
    ///
    /// Blocking and CPU-bound; call it off the main actor.
    static func `import`(from source: URL,
                         into destinationDirectory: URL,
                         progress: (@Sendable (Double) -> Void)? = nil) throws -> InstalledDictionary {
        var scratch: URL?
        defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw StarDictImportError.unreadableSource
        }

        let folder: URL
        if isDirectory.boolValue {
            folder = source
        } else if source.pathExtension.lowercased() == "zip" {
            let temp = fileManager.temporaryDirectory
                .appendingPathComponent("stardict-\(UUID().uuidString)", isDirectory: true)
            scratch = temp
            do {
                try ZIPArchive.extract(source, into: temp)
            } catch {
                throw StarDictImportError.unreadableArchive
            }
            folder = temp
        } else if source.pathExtension.lowercased() == "ifo" {
            folder = source.deletingLastPathComponent()
        } else {
            throw StarDictImportError.unsupportedSource(source.pathExtension.lowercased())
        }
        progress?(0.05)

        guard let ifoURL = locateInfoFile(in: folder) else {
            throw StarDictImportError.missingInfoFile
        }
        let info = try parseInfo(at: ifoURL)
        progress?(0.1)

        let base = ifoURL.deletingPathExtension()
        let directory = ifoURL.deletingLastPathComponent()

        guard let indexURL = companion(base: base, in: directory, extensions: ["idx", "idx.gz"]) else {
            throw StarDictImportError.missingIndexFile
        }
        guard let dictURL = companion(base: base, in: directory, extensions: ["dict", "dict.dz"]) else {
            throw StarDictImportError.missingDictionaryFile
        }

        let indexBytes = try loadPossiblyCompressed(indexURL)
        let records = try parseIndex(indexBytes, offsetBits: info.idxOffsetBits)
        progress?(0.25)

        let dictBytes = try loadPossiblyCompressed(dictURL)
        progress?(0.3)

        // Definitions are shared by reference with any synonym rows below, so
        // a headword with ten synonyms still stores the text only once.
        var definitions = [String?](repeating: nil, count: records.count)
        var rows: [(word: String, definition: String)] = []
        rows.reserveCapacity(records.count)

        for (index, record) in records.enumerated() {
            if let text = definition(in: dictBytes, offset: record.offset, size: record.size,
                                     sameTypeSequence: info.sameTypeSequence), !text.isEmpty {
                definitions[index] = text
                rows.append((record.word, text))
            }
            if index % 4096 == 0 {
                progress?(0.3 + 0.45 * Double(index) / Double(max(records.count, 1)))
            }
        }
        progress?(0.75)

        if let synURL = companion(base: base, in: directory, extensions: ["syn", "syn.gz"]),
           let synBytes = try? loadPossiblyCompressed(synURL) {
            for (synonym, index) in parseSynonyms(synBytes, entryCount: records.count) {
                if let text = definitions[index] {
                    rows.append((synonym, text))
                }
            }
        }
        progress?(0.8)

        guard !rows.isEmpty else { throw StarDictImportError.emptyDictionary }

        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let fileName = "\(slug(info.bookname))-\(UUID().uuidString.prefix(8)).sqlite"
        let destination = destinationDirectory.appendingPathComponent(fileName)

        var meta = ["bookname": info.bookname, "wordcount": "\(rows.count)"]
        if let language = info.language { meta["language"] = language }
        if let version = info.version { meta["stardict_version"] = version }
        meta["source"] = ifoURL.deletingPathExtension().lastPathComponent

        do {
            try writeDatabase(at: destination, meta: meta, rows: rows) { fraction in
                progress?(0.8 + 0.2 * fraction)
            }
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        progress?(1.0)

        return InstalledDictionary(name: info.bookname, language: info.language,
                                   wordCount: rows.count, fileURL: destination)
    }

    // MARK: - .ifo

    struct Info {
        var bookname: String
        var wordCount: Int
        var idxFileSize: Int
        var sameTypeSequence: String
        var version: String?
        var idxOffsetBits: Int
        var language: String?
    }

    private static func parseInfo(at url: URL) throws -> Info {
        guard let data = try? Data(contentsOf: url) else {
            throw StarDictImportError.malformedInfoFile
        }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: .newlines)
        guard let magic = lines.first, magic.contains("StarDict") else {
            throw StarDictImportError.malformedInfoFile
        }
        lines.removeFirst()

        var fields: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            fields[key.lowercased()] = value
        }

        let bookname = fields["bookname"].flatMap { $0.isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent

        // Some dictionaries name the languages separately rather than in one key.
        let language: String?
        if let explicit = fields["lang"] ?? fields["language"], !explicit.isEmpty {
            language = explicit
        } else if let from = fields["sourcelang"], !from.isEmpty {
            if let to = fields["targetlang"], !to.isEmpty {
                language = "\(from) - \(to)"
            } else {
                language = from
            }
        } else {
            language = nil
        }

        let offsetBits = fields["idxoffsetbits"].flatMap(Int.init) ?? 32
        return Info(bookname: bookname,
                    wordCount: fields["wordcount"].flatMap(Int.init) ?? 0,
                    idxFileSize: fields["idxfilesize"].flatMap(Int.init) ?? 0,
                    sameTypeSequence: fields["sametypesequence"] ?? "",
                    version: fields["version"],
                    idxOffsetBits: offsetBits == 64 ? 64 : 32,
                    language: language)
    }

    // MARK: - .idx

    private struct IndexRecord {
        let word: String
        let offset: Int
        let size: Int
    }

    private static func parseIndex(_ bytes: [UInt8], offsetBits: Int) throws -> [IndexRecord] {
        let offsetWidth = offsetBits == 64 ? 8 : 4
        let count = bytes.count
        var cursor = 0
        var records: [IndexRecord] = []

        while cursor < count {
            guard let nul = bytes[cursor..<count].firstIndex(of: 0) else { break }
            let word = String(decoding: bytes[cursor..<nul], as: UTF8.self)
            cursor = nul + 1
            guard count - cursor >= offsetWidth + 4 else { break }

            let offset: Int
            if offsetWidth == 8 {
                let raw = readUInt64BE(bytes, cursor)
                guard raw <= UInt64(Int.max) else { break }
                offset = Int(raw)
            } else {
                offset = Int(readUInt32BE(bytes, cursor))
            }
            cursor += offsetWidth
            let size = Int(readUInt32BE(bytes, cursor))
            cursor += 4

            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            records.append(IndexRecord(word: trimmed, offset: offset, size: size))
        }

        guard !records.isEmpty else { throw StarDictImportError.malformedIndex }
        return records
    }

    // MARK: - .syn

    /// Synonyms point at a position in the sorted word list; out-of-range or
    /// truncated records are dropped rather than failing the whole import.
    private static func parseSynonyms(_ bytes: [UInt8], entryCount: Int) -> [(String, Int)] {
        let count = bytes.count
        var cursor = 0
        var result: [(String, Int)] = []

        while cursor < count {
            guard let nul = bytes[cursor..<count].firstIndex(of: 0) else { break }
            let word = String(decoding: bytes[cursor..<nul], as: UTF8.self)
            cursor = nul + 1
            guard count - cursor >= 4 else { break }
            let index = Int(readUInt32BE(bytes, cursor))
            cursor += 4

            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, index >= 0, index < entryCount else { continue }
            result.append((trimmed, index))
        }
        return result
    }

    // MARK: - .dict

    /// Renders one entry's payload as plain text, or nil if it holds nothing
    /// readable (a pure image or sound entry, say).
    private static func definition(in dict: [UInt8], offset: Int, size: Int,
                                   sameTypeSequence: String) -> String? {
        guard size > 0, offset >= 0, dict.count - offset >= size else { return nil }
        let end = offset + size
        var cursor = offset
        var parts: [String] = []

        if !sameTypeSequence.isEmpty {
            let types = Array(sameTypeSequence.utf8)
            for (index, type) in types.enumerated() {
                guard cursor <= end else { break }
                let fieldStart: Int
                let fieldEnd: Int

                if index == types.count - 1 {
                    // The final field's length is implied by the entry size.
                    fieldStart = cursor
                    fieldEnd = end
                    cursor = end
                } else if isLowercaseASCIILetter(type) {
                    fieldStart = cursor
                    guard let nul = dict[cursor..<end].firstIndex(of: 0) else { break }
                    fieldEnd = nul
                    cursor = nul + 1
                } else {
                    guard end - cursor >= 4 else { break }
                    let length = Int(readUInt32BE(dict, cursor))
                    cursor += 4
                    guard end - cursor >= length else { break }
                    fieldStart = cursor
                    fieldEnd = cursor + length
                    cursor = fieldEnd
                }

                if let text = render(type: type, bytes: trimmingTrailingNULs(dict[fieldStart..<fieldEnd])),
                   !text.isEmpty {
                    parts.append(text)
                }
            }
        } else {
            while cursor < end {
                let type = dict[cursor]
                cursor += 1
                let fieldStart: Int
                let fieldEnd: Int

                if isLowercaseASCIILetter(type) {
                    fieldStart = cursor
                    if let nul = dict[cursor..<end].firstIndex(of: 0) {
                        fieldEnd = nul
                        cursor = nul + 1
                    } else {
                        fieldEnd = end
                        cursor = end
                    }
                } else if isUppercaseASCIILetter(type) {
                    guard end - cursor >= 4 else { break }
                    let length = Int(readUInt32BE(dict, cursor))
                    cursor += 4
                    guard length >= 0, end - cursor >= length else { break }
                    fieldStart = cursor
                    fieldEnd = cursor + length
                    cursor = fieldEnd
                } else {
                    break // Not a type character: the entry is malformed.
                }

                if let text = render(type: type, bytes: dict[fieldStart..<fieldEnd]), !text.isEmpty {
                    parts.append(text)
                }
            }
        }

        let joined = parts.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    private static func render(type: UInt8, bytes: ArraySlice<UInt8>) -> String? {
        switch Character(UnicodeScalar(type)) {
        case "m", "l", "t", "y", "k", "w", "n":
            return String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case "g", "h", "x":
            return plainText(fromMarkup: String(decoding: bytes, as: UTF8.self))
        default:
            // 'W'/'P' and friends are binary payloads, and 'r' is a resource
            // file list; none of them belong in a definition.
            return nil
        }
    }

    // MARK: - Markup

    private static let blockLevelTags: Set<String> = [
        "br", "p", "div", "tr", "li", "ul", "ol", "dl", "dt", "dd", "hr", "table",
        "blockquote", "pre", "section", "article", "h1", "h2", "h3", "h4", "h5", "h6",
        // XDXF elements that separate blocks in practice.
        "k", "def", "ex", "co", "dtrn",
    ]

    /// Flattens Pango markup, HTML or XDXF into readable plain text.
    static func plainText(fromMarkup markup: String) -> String {
        var stripped = ""
        stripped.reserveCapacity(markup.count)

        var index = markup.startIndex
        while index < markup.endIndex {
            let character = markup[index]
            guard character == "<" else {
                stripped.append(character)
                index = markup.index(after: index)
                continue
            }
            guard let close = markup[index...].firstIndex(of: ">") else {
                // A bare "<" that never closes is literal text, not a tag.
                stripped.append(contentsOf: markup[index...])
                break
            }
            let body = markup[markup.index(after: index)..<close]
            if blockLevelTags.contains(tagName(body)) {
                stripped.append("\n")
            }
            index = markup.index(after: close)
        }
        return tidied(decodingEntities(stripped))
    }

    private static func tagName(_ body: Substring) -> String {
        var name = body
        if name.hasPrefix("/") { name = name.dropFirst() }
        let end = name.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "/" })
            ?? name.endIndex
        return name[name.startIndex..<end].lowercased()
    }

    private static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        output.reserveCapacity(text.count)

        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&" else {
                output.append(text[index])
                index = text.index(after: index)
                continue
            }
            var cursor = text.index(after: index)
            var terminator: String.Index?
            var steps = 0
            while cursor < text.endIndex, steps < 12 {
                let character = text[cursor]
                if character == ";" { terminator = cursor; break }
                if character == "&" || character == " " || character == "\n" { break }
                cursor = text.index(after: cursor)
                steps += 1
            }
            guard let semicolon = terminator,
                  let replacement = entity(String(text[text.index(after: index)..<semicolon]))
            else {
                output.append("&")
                index = text.index(after: index)
                continue
            }
            output.append(replacement)
            index = text.index(after: semicolon)
        }
        return output
    }

    private static func entity(_ name: String) -> String? {
        switch name.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default: break
        }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let value: UInt32?
        if digits.hasPrefix("x") || digits.hasPrefix("X") {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }

    /// Trims each line and collapses blank-line runs, which markup conversion
    /// produces in quantity.
    private static func tidied(_ text: String) -> String {
        var lines: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: - SQLite output

    private static func writeDatabase(at url: URL, meta: [String: String],
                                      rows: [(word: String, definition: String)],
                                      progress: (Double) -> Void) throws {
        try? FileManager.default.removeItem(at: url)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            throw StarDictImportError.databaseWriteFailed("could not create the database file")
        }
        defer { sqlite3_close(db) }

        // The file is rebuilt from scratch on failure, so durability during the
        // bulk load buys nothing and costs a great deal of time.
        try execute(db, "PRAGMA journal_mode=OFF")
        try execute(db, "PRAGMA synchronous=OFF")
        try execute(db, "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT)")
        try execute(db, """
            CREATE TABLE entries(id INTEGER PRIMARY KEY, word TEXT NOT NULL,
                                 word_lower TEXT NOT NULL, definition TEXT NOT NULL)
            """)
        try execute(db, "BEGIN")

        try insertEntries(db, rows: rows, progress: progress)
        try insertMeta(db, meta: meta)

        try execute(db, "COMMIT")
        // Building the index after the load is far cheaper than maintaining it
        // across 100k inserts.
        try execute(db, "CREATE INDEX idx_entries_lower ON entries(word_lower)")
    }

    private static func insertEntries(_ db: OpaquePointer,
                                      rows: [(word: String, definition: String)],
                                      progress: (Double) -> Void) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "INSERT INTO entries(word, word_lower, definition) VALUES(?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StarDictImportError.databaseWriteFailed(lastErrorMessage(db))
        }

        for (index, row) in rows.enumerated() {
            sqlite3_bind_text(statement, 1, row.word, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, row.word.lowercased(), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, row.definition, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw StarDictImportError.databaseWriteFailed(lastErrorMessage(db))
            }
            sqlite3_reset(statement)
            if index % 4096 == 0 {
                progress(Double(index) / Double(max(rows.count, 1)))
            }
        }
    }

    private static func insertMeta(_ db: OpaquePointer, meta: [String: String]) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "INSERT INTO meta(key, value) VALUES(?, ?)",
                                 -1, &statement, nil) == SQLITE_OK else {
            throw StarDictImportError.databaseWriteFailed(lastErrorMessage(db))
        }
        for (key, value) in meta {
            sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, value, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw StarDictImportError.databaseWriteFailed(lastErrorMessage(db))
            }
            sqlite3_reset(statement)
        }
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StarDictImportError.databaseWriteFailed(lastErrorMessage(db))
        }
    }

    private static func lastErrorMessage(_ db: OpaquePointer) -> String {
        guard let message = sqlite3_errmsg(db) else { return "unknown error" }
        return String(cString: message)
    }

    // MARK: - Files

    private static func locateInfoFile(in folder: URL) -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }

        var candidates: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "ifo" {
            candidates.append(url)
        }
        // Shallowest first, so a dictionary next to its own "res" folder wins.
        return candidates.min { $0.pathComponents.count < $1.pathComponents.count }
    }

    /// Finds `base.ext`, falling back to any file in `directory` with that
    /// extension — some archives rename the data files but not the .ifo.
    private static func companion(base: URL, in directory: URL, extensions: [String]) -> URL? {
        let fileManager = FileManager.default
        for ext in extensions {
            let candidate = URL(fileURLWithPath: base.path + "." + ext)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return nil }
        for ext in extensions {
            if let match = contents.first(where: { $0.lastPathComponent.lowercased().hasSuffix("." + ext) }) {
                return match
            }
        }
        return nil
    }

    private static func loadPossiblyCompressed(_ url: URL) throws -> [UInt8] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw StarDictImportError.unreadableSource
        }
        let name = url.lastPathComponent.lowercased()
        guard name.hasSuffix(".gz") || name.hasSuffix(".dz") else { return [UInt8](data) }
        do {
            return try Zlib.gunzip(data)
        } catch {
            throw StarDictImportError.decompressionFailed
        }
    }

    private static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let joined = String(cleaned).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "dictionary" : String(joined.prefix(48))
    }

    // MARK: - Bytes

    private static func isLowercaseASCIILetter(_ byte: UInt8) -> Bool {
        byte >= 0x61 && byte <= 0x7A
    }

    private static func isUppercaseASCIILetter(_ byte: UInt8) -> Bool {
        byte >= 0x41 && byte <= 0x5A
    }

    private static func trimmingTrailingNULs(_ slice: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var result = slice
        while let last = result.last, last == 0 { result = result.dropLast() }
        return result
    }

    private static func readUInt32BE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 { value = (value << 8) | UInt32(bytes[offset + index]) }
        return value
    }

    private static func readUInt64BE(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value = (value << 8) | UInt64(bytes[offset + index]) }
        return value
    }
}
