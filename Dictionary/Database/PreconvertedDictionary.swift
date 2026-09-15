import Foundation
import SQLite3

enum PreconvertedDictionaryError: LocalizedError {
    case notADatabase
    case missingTables
    case noEntries
    case unreadableMeta

    var errorDescription: String? {
        switch self {
        case .notADatabase:
            return "That file is not a dictionary database."
        case .missingTables:
            return "The dictionary is missing its word list."
        case .noEntries:
            return "The dictionary is empty."
        case .unreadableMeta:
            return "The dictionary has no readable name."
        }
    }
}

/// A dictionary that already arrives in the app's SQLite format, so it can be
/// installed without going through `StarDictImporter`.
///
/// The file is validated before it is copied into the library: a half-written
/// download or an HTML error page saved under a `.sqlite` name must fail here
/// with something a reader can act on, not later as a silent empty dictionary.
enum PreconvertedDictionary {
    struct Summary: Sendable {
        let bookname: String
        let language: String?
        let entryCount: Int
    }

    static func validate(at url: URL) throws -> Summary {
        // sqlite3_open_v2 succeeds on anything, including an HTML error page
        // saved under this name, so check the file header before opening it.
        guard let handle = try? FileHandle(forReadingFrom: url),
              let header = try? handle.read(upToCount: 16),
              header == Data("SQLite format 3\0".utf8) else {
            throw PreconvertedDictionaryError.notADatabase
        }
        try? handle.close()

        var handle2: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle2, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle2 else {
            sqlite3_close(handle2)
            throw PreconvertedDictionaryError.notADatabase
        }
        defer { sqlite3_close(db) }

        let tables = Set(queryStrings(db, """
            SELECT name FROM sqlite_master WHERE type='table'
            AND name IN ('meta','entries')
            """))
        guard tables.contains("meta"), tables.contains("entries") else {
            throw PreconvertedDictionaryError.missingTables
        }

        guard let bookname = queryStrings(db,
            "SELECT value FROM meta WHERE key='bookname'").first,
              !bookname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PreconvertedDictionaryError.unreadableMeta
        }

        guard let count = queryStrings(db, "SELECT count(*) FROM entries")
            .first.flatMap(Int.init), count > 0 else {
            throw PreconvertedDictionaryError.noEntries
        }

        // One real row, so a table with a wrong column layout is caught too.
        guard !queryStrings(db,
            "SELECT word FROM entries WHERE word_lower IS NOT NULL LIMIT 1").isEmpty else {
            throw PreconvertedDictionaryError.missingTables
        }

        let language = queryStrings(db, "SELECT value FROM meta WHERE key='language'").first
        return Summary(bookname: bookname,
                       language: language?.isEmpty == false ? language : nil,
                       entryCount: count)
    }

    private static func queryStrings(_ db: OpaquePointer, _ sql: String) -> [String] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        var results: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                results.append(String(cString: text))
            }
        }
        return results
    }
}
