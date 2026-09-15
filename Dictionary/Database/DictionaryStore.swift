import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Read-only access to the bundled WordNet SQLite database.
///
/// All methods are synchronous and thread-safe for concurrent reads because
/// the database is opened read-only and never modified.
final class DictionaryStore {
    static let shared = DictionaryStore()

    private var db: OpaquePointer?

    private init() {
        guard let url = Bundle.main.url(forResource: "WordNet", withExtension: "sqlite") else {
            assertionFailure("WordNet.sqlite missing from app bundle")
            return
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK {
            db = handle
        } else {
            sqlite3_close(handle)
            assertionFailure("Unable to open WordNet.sqlite")
        }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Search

    /// Words matching the query, prefix matches first (shortest first, like
    /// the macOS Dictionary sidebar), then substring matches.
    func suggestions(matching query: String, limit: Int = 80) -> [String] {
        let term = normalized(query)
        guard !term.isEmpty else { return [] }

        var results: [String] = []
        var seen = Set<String>()

        let prefixSQL = """
            SELECT word FROM words WHERE word_lower LIKE ? ESCAPE '\\'
            ORDER BY length(word_lower), word_lower LIMIT ?
            """
        for word in queryStrings(prefixSQL, bindings: [escapedLike(term) + "%", "\(limit)"]) {
            if seen.insert(word.lowercased()).inserted { results.append(word) }
        }

        if results.count < limit && term.count >= 3 {
            let containsSQL = """
                SELECT word FROM words WHERE word_lower LIKE ? ESCAPE '\\'
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

    /// Full lookup with fallbacks: exact match, irregular inflected forms
    /// ("went" -> "go"), regular de-inflection ("running" -> "run"), then
    /// spelling suggestions.
    func lookup(_ query: String) -> LookupResult {
        let term = normalized(query)
        guard !term.isEmpty else { return .notFound(suggestions: []) }

        if let entry = entry(forExactWord: term) {
            return .found(entry)
        }

        let bases = queryStrings("SELECT base FROM forms WHERE form = ?", bindings: [term])
        let baseEntries = bases.compactMap { entry(forExactWord: $0) }
        if !baseEntries.isEmpty {
            return .redirected(from: query.trimmingCharacters(in: .whitespacesAndNewlines),
                               entries: baseEntries)
        }

        for candidate in morphologicalCandidates(for: term) {
            if let entry = entry(forExactWord: candidate) {
                return .redirected(from: query.trimmingCharacters(in: .whitespacesAndNewlines),
                                   entries: [entry])
            }
        }

        return .notFound(suggestions: spellingSuggestions(for: term))
    }

    /// The entry whose headword matches exactly (case-insensitive).
    func entry(forExactWord word: String) -> WordEntry? {
        let term = normalized(word)
        guard !term.isEmpty, let db else { return nil }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT id, word, pronunciation FROM words WHERE word_lower = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, term, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let id = sqlite3_column_int64(stmt, 0)
        let headword = String(cString: sqlite3_column_text(stmt, 1))
        let pronunciation = sqlite3_column_text(stmt, 2).map { String(cString: $0) }

        return WordEntry(id: id, word: headword, pronunciation: pronunciation,
                         senses: senses(forWordID: id))
    }

    /// A random headword, for the "random word" discovery feature. Seeks to a
    /// random id rather than sorting the whole table with `ORDER BY RANDOM()`,
    /// which a twenty-card deck would otherwise do twenty times.
    func randomWord() -> String? {
        queryStrings("""
            SELECT word FROM words
            WHERE id >= (SELECT abs(random()) % max(id) + 1 FROM words)
            ORDER BY id LIMIT 1
            """, bindings: []).first
    }

    // MARK: - Private

    private func senses(forWordID id: Int64) -> [WordSense] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT id, pos, sense_number, definition, examples, synonyms, antonyms
            FROM senses WHERE word_id = ? ORDER BY pos, sense_number
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(stmt, 1, id)

        var senses: [WordSense] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            senses.append(WordSense(
                id: sqlite3_column_int64(stmt, 0),
                partOfSpeech: String(cString: sqlite3_column_text(stmt, 1)),
                senseNumber: Int(sqlite3_column_int(stmt, 2)),
                definition: String(cString: sqlite3_column_text(stmt, 3)),
                examples: jsonArray(sqlite3_column_text(stmt, 4)),
                synonyms: jsonArray(sqlite3_column_text(stmt, 5)),
                antonyms: jsonArray(sqlite3_column_text(stmt, 6))
            ))
        }
        return senses
    }

    /// WordNet "Morphy"-style regular de-inflection rules.
    private func morphologicalCandidates(for term: String) -> [String] {
        var candidates: [String] = []
        let rules: [(suffix: String, replacements: [String])] = [
            ("ses", ["s"]), ("xes", ["x"]), ("zes", ["z"]), ("ches", ["ch"]),
            ("shes", ["sh"]), ("ies", ["y"]), ("ves", ["f", "fe"]),
            ("men", ["man"]), ("ing", ["", "e"]), ("ed", ["", "e"]),
            ("est", ["", "e"]), ("er", ["", "e"]), ("es", ["", "e"]), ("s", [""]),
        ]
        for rule in rules where term.hasSuffix(rule.suffix) && term.count > rule.suffix.count + 1 {
            let stem = String(term.dropLast(rule.suffix.count))
            for replacement in rule.replacements {
                candidates.append(stem + replacement)
            }
            // Doubled final consonant: "running" -> "run"
            if (rule.suffix == "ing" || rule.suffix == "ed" || rule.suffix == "er"
                || rule.suffix == "est"),
               stem.count >= 2, let last = stem.last,
               stem[stem.index(stem.endIndex, offsetBy: -2)] == last {
                candidates.append(String(stem.dropLast()))
            }
        }
        return candidates
    }

    /// Closest spellings by edit distance among words sharing the first letter
    /// and a similar length.
    private func spellingSuggestions(for term: String, limit: Int = 12) -> [String] {
        guard let first = term.first, let db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT word, word_lower FROM words
            WHERE word_lower >= ? AND word_lower < ?
            AND length(word_lower) BETWEEN ? AND ?
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        let lower = String(first)
        let upper = String(first) + "\u{FFFF}"
        sqlite3_bind_text(stmt, 1, lower, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, upper, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(max(1, term.count - 2)))
        sqlite3_bind_int(stmt, 4, Int32(term.count + 2))

        var scored: [(word: String, distance: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let display = String(cString: sqlite3_column_text(stmt, 0))
            let key = String(cString: sqlite3_column_text(stmt, 1))
            let distance = editDistance(term, key, cap: 3)
            if distance <= 2 {
                scored.append((display, distance))
            }
        }
        return scored
            .sorted { ($0.distance, $0.word.count, $0.word) < ($1.distance, $1.word.count, $1.word) }
            .prefix(limit)
            .map(\.word)
    }

    private func editDistance(_ a: String, _ b: String, cap: Int) -> Int {
        let a = Array(a.unicodeScalars), b = Array(b.unicodeScalars)
        if abs(a.count - b.count) > cap { return cap + 1 }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            current[0] = i
            var rowMin = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > cap { return cap + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    private func queryStrings(_ sql: String, bindings: [String]) -> [String] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
        }
        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0) {
                results.append(String(cString: text))
            }
        }
        return results
    }

    private func jsonArray(_ text: UnsafePointer<UInt8>?) -> [String] {
        guard let text, let data = String(cString: text).data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return array
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
