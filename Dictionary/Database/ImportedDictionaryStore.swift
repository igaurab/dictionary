import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Read-only access to one dictionary produced by `StarDictImporter`.
///
/// Mirrors `DictionaryStore`: opened read-only and never written, so reads are
/// safe from any thread.
final class ImportedDictionaryStore {
    let name: String
    let wordCount: Int

    private let db: OpaquePointer

    init?(url: URL) {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        // A file that does not answer to the expected schema is not ours.
        guard let name = Self.metaValue(handle, key: "bookname") else {
            sqlite3_close(handle)
            return nil
        }
        self.db = handle
        self.name = name
        self.wordCount = Self.metaValue(handle, key: "wordcount").flatMap(Int.init) ?? 0
    }

    deinit {
        sqlite3_close(db)
    }

    /// The language recorded in the source .ifo, when it had one.
    var language: String? {
        Self.metaValue(db, key: "language")
    }

    // MARK: - Search

    /// Prefix matches first (shortest first), then substring matches — the same
    /// ordering as the bundled dictionary.
    func suggestions(matching query: String, limit: Int = 80) -> [String] {
        let term = normalized(query)
        guard !term.isEmpty, limit > 0 else { return [] }

        var results: [String] = []
        var seen = Set<String>()

        let prefixSQL = """
            SELECT DISTINCT word FROM entries WHERE word_lower LIKE ? ESCAPE '\\'
            ORDER BY length(word_lower), word_lower LIMIT ?
            """
        for word in queryStrings(prefixSQL, bindings: [escapedLike(term) + "%", "\(limit)"]) {
            if seen.insert(word.lowercased()).inserted { results.append(word) }
        }

        if results.count < limit && term.count >= 3 {
            let containsSQL = """
                SELECT DISTINCT word FROM entries WHERE word_lower LIKE ? ESCAPE '\\'
                AND word_lower NOT LIKE ? ESCAPE '\\'
                ORDER BY length(word_lower), word_lower LIMIT ?
                """
            let escaped = escapedLike(term)
            for word in queryStrings(containsSQL,
                                     bindings: ["%" + escaped + "%", escaped + "%",
                                                "\(limit - results.count)"]) {
                if seen.insert(word.lowercased()).inserted { results.append(word) }
            }
        }
        return results
    }

    /// The definition for a headword, case-insensitive. StarDict allows several
    /// entries under one headword, so they are joined in index order.
    func definition(for word: String) -> String? {
        let term = normalized(word)
        guard !term.isEmpty else { return nil }
        let texts = queryStrings("SELECT definition FROM entries WHERE word_lower = ? ORDER BY id",
                                 bindings: [term])
        guard !texts.isEmpty else { return nil }

        var seen = Set<String>()
        let unique = texts.filter { seen.insert($0).inserted }
        return unique.joined(separator: "\n\n")
    }

    func contains(_ word: String) -> Bool {
        let term = normalized(word)
        guard !term.isEmpty else { return false }
        return !queryStrings("SELECT 1 FROM entries WHERE word_lower = ? LIMIT 1",
                             bindings: [term]).isEmpty
    }

    // MARK: - Private

    private static func metaValue(_ db: OpaquePointer, key: String) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?",
                                 -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private func queryStrings(_ sql: String, bindings: [String]) -> [String] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
        }
        var results: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                results.append(String(cString: text))
            }
        }
        return results
    }

    private func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func escapedLike(_ term: String) -> String {
        term.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
