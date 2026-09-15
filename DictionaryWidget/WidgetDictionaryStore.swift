import Foundation
import SQLite3


/// The slice of a dictionary entry a widget can actually show.
struct WidgetWord {
    let word: String
    let pronunciation: String?
    let partOfSpeech: String
    let definition: String
}

/// Read-only access to the widget extension's own copy of WordNet.sqlite.
///
/// App Groups need a paid developer account, so the extension can't reach into
/// a container shared with the app. Instead the same `WordNet.sqlite` is a
/// member of both targets' resources: the app reads the copy in `Dictionary.app`
/// and the widget reads the one in `Dictionary.app/PlugIns/DictionaryWidget.appex`.
/// It costs ~38 MB of duplicated payload and buys a widget that needs no
/// entitlement at all.
final class WidgetDictionaryStore {
    static let shared = WidgetDictionaryStore()

    private var db: OpaquePointer?

    private init() {
        guard let url = Bundle.main.url(forResource: "WordNet", withExtension: "sqlite") else { return }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK {
            db = handle
        } else {
            sqlite3_close(handle)
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: - Word of the day

    /// The word for a given calendar day.
    ///
    /// Deliberately a pure function of the day: WidgetKit reloads a timeline
    /// whenever it feels like it, and a word that reshuffled on every reload
    /// would not be a word of the *day*. The same date always hashes to the
    /// same headword.
    func wordOfTheDay(for date: Date, calendar: Calendar = .current) -> WidgetWord? {
        let seed = Self.rowSeed(for: date, calendar: calendar)
        guard let (id, word, pronunciation) = headword(atOrAfter: seed) ?? headword(atOrAfter: 0)
        else { return nil }
        guard let sense = firstSense(wordID: id) else { return nil }
        return WidgetWord(word: word, pronunciation: pronunciation,
                          partOfSpeech: sense.pos, definition: sense.definition)
    }

    /// Days since the reference date, hashed and folded into the `words.id`
    /// range. Exact day arithmetic (rather than dividing a time interval) so a
    /// DST change can't make two days collide or skip one.
    static func dayIndex(for date: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        return calendar.dateComponents([.day], from: epoch, to: start).day ?? 0
    }

    private static func rowSeed(for date: Date, calendar: Calendar) -> Int64 {
        // SplitMix64: cheap, deterministic, and it decorrelates consecutive
        // days so the widget doesn't walk the dictionary alphabetically.
        var x = UInt64(bitPattern: Int64(dayIndex(for: date, calendar: calendar))) &+ 0x9E3779B97F4A7C15
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        x ^= x >> 31
        return Int64(x % UInt64(maxWordID))
    }

    /// `words.id` runs 1...147478 in the bundled build of WordNet 3.1. A seed
    /// past the end simply wraps, so an over- or under-estimate is harmless.
    private static let maxWordID = 147_478

    // MARK: - Private

    /// The first headword at or after `id` that reads well in a widget: a
    /// single lowercase word of ordinary length with a pronunciation. Scanning
    /// forward by rowid is an index walk, and roughly one word in five
    /// qualifies, so it stops within a handful of rows.
    private func headword(atOrAfter id: Int64) -> (Int64, String, String?)? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT id, word, pronunciation FROM words
            WHERE id >= ?
              AND word = word_lower
              AND pronunciation IS NOT NULL
              AND length(word) BETWEEN 6 AND 14
              AND word NOT LIKE '% %'
              AND word NOT LIKE '%-%'
              AND word NOT LIKE '%.%'
              AND word NOT LIKE '%''%'
            ORDER BY id LIMIT 1
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (sqlite3_column_int64(stmt, 0),
                String(cString: sqlite3_column_text(stmt, 1)),
                sqlite3_column_text(stmt, 2).map { String(cString: $0) })
    }

    /// The sense the app itself shows first: senses are grouped noun, verb,
    /// adjective, adverb, and sense 1 of the first group leads the entry.
    private func firstSense(wordID: Int64) -> (pos: String, definition: String)? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT pos, definition FROM senses
            WHERE word_id = ? ORDER BY pos, sense_number
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(stmt, 1, wordID)

        var byPOS: [String: (pos: String, definition: String)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let pos = String(cString: sqlite3_column_text(stmt, 0))
            guard byPOS[pos] == nil else { continue }
            byPOS[pos] = (pos, String(cString: sqlite3_column_text(stmt, 1)))
        }
        for pos in ["noun", "verb", "adjective", "adverb"] {
            if let sense = byPOS[pos] { return sense }
        }
        return byPOS.values.first
    }
}
