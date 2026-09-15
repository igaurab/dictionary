import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import SQLite3

private let SQLITE_TRANSIENT_IDX = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Publishes the dictionary to Spotlight so a word can be looked up from the
/// home screen's swipe-down search without opening the app first.
///
/// The index is built once and then left alone: the bundled dictionary never
/// changes, so re-indexing on every launch would burn battery for nothing.
/// `indexedVersion` is bumped whenever the shape of the items changes.
enum SpotlightIndexer {
    static let domain = "com.igaurab.Dictionary.words"

    /// Bump to force a rebuild after changing what gets indexed.
    private static let indexedVersion = 1
    private static let versionKey = "spotlightIndexedVersion"
    private static let enabledKey = "spotlightIndexingEnabled"

    /// Indexing 147,000 entries is worth it for the payoff, but it is not
    /// something to do behind the user's back on a metered device, so it is a
    /// setting. Defaults to on because the whole point is that it just works.
    static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue {
                Task.detached(priority: .utility) { await indexIfNeeded(force: true) }
            } else {
                Task.detached(priority: .utility) { await deleteIndex() }
            }
        }
    }

    static func indexIfNeeded(force: Bool = false) async {
        guard isEnabled, CSSearchableIndex.isIndexingAvailable() else { return }
        let defaults = UserDefaults.standard
        guard force || defaults.integer(forKey: versionKey) != indexedVersion else { return }

        do {
            try await buildIndex()
            defaults.set(indexedVersion, forKey: versionKey)
        } catch {
            // A failed index is a degraded feature, not a broken app: the next
            // launch retries because the version key was never written.
            defaults.set(0, forKey: versionKey)
        }
    }

    static func deleteIndex() async {
        try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
        UserDefaults.standard.set(0, forKey: versionKey)
    }

    // MARK: - Building

    /// Streams word + first definition straight out of the bundled database in
    /// batches. A per-word lookup would mean 147,000 round trips, and holding
    /// every item in memory at once would be hundreds of megabytes.
    private static func buildIndex() async throws {
        guard let url = Bundle.main.url(forResource: "WordNet", withExtension: "sqlite") else { return }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_close(db) }

        // One row per word: its pronunciation and the lowest-numbered sense,
        // which is the gloss a reader expects to see first.
        let sql = """
            SELECT w.word, (
                SELECT s.definition FROM senses s
                WHERE s.word_id = w.id
                ORDER BY s.sense_number LIMIT 1
            )
            FROM words w
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_finalize(stmt) }

        let index = CSSearchableIndex.default()
        var batch: [CSSearchableItem] = []
        batch.reserveCapacity(batchSize)

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let wordC = sqlite3_column_text(stmt, 0) else { continue }
            let word = String(cString: wordC)

            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = word
            if let defC = sqlite3_column_text(stmt, 1) {
                attributes.contentDescription = String(cString: defC)
            }
            // Spotlight matches on keywords more aggressively than on title,
            // which is what makes a partial word find the entry.
            attributes.keywords = [word]

            batch.append(CSSearchableItem(uniqueIdentifier: word,
                                          domainIdentifier: domain,
                                          attributeSet: attributes))

            if batch.count >= batchSize {
                try await index.indexSearchableItems(batch)
                batch.removeAll(keepingCapacity: true)
                await Task.yield()
            }
        }

        if !batch.isEmpty {
            try await index.indexSearchableItems(batch)
        }
    }

    private static let batchSize = 2_000
}
