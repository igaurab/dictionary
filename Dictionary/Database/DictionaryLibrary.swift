import Foundation
import SwiftUI

/// Owns the user's imported dictionaries: the manifest, the enabled set, and
/// the open read-only stores.
///
/// Generated databases live in Application Support/Dictionaries and are kept
/// out of backups — they can be tens of megabytes and are always re-importable
/// from the original StarDict files.
@MainActor
final class DictionaryLibrary: ObservableObject {
    static let shared = DictionaryLibrary()

    @Published private(set) var installed: [InstalledDictionary] = []

    @Published var enabledIDs: Set<UUID> = [] {
        didSet {
            guard enabledIDs != oldValue else { return }
            persistEnabledIDs()
            openStores = openStores.filter { enabledIDs.contains($0.key) }
        }
    }

    /// 0...1 while an import runs, nil otherwise. Drives the Settings progress view.
    @Published private(set) var importProgress: Double?

    /// 0...1 per catalogue id while that dictionary downloads.
    @Published private(set) var downloadProgress: [String: Double] = [:]

    private var openStores: [UUID: ImportedDictionaryStore] = [:]
    private let defaults: UserDefaults
    private static let enabledDefaultsKey = "DictionaryLibrary.enabledIDs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        installed = Self.loadManifest()
        let known = Set(installed.map(\.id))
        if let stored = defaults.array(forKey: Self.enabledDefaultsKey) as? [String] {
            enabledIDs = Set(stored.compactMap(UUID.init(uuidString:))).intersection(known)
        } else {
            // First run after an import elsewhere: everything present is on.
            enabledIDs = known
        }
    }

    // MARK: - Storage locations

    /// Application Support/Dictionaries, created on first use.
    static let storageDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        var directory = base.appendingPathComponent("Dictionaries", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return directory
    }()

    private static var manifestURL: URL {
        storageDirectory.appendingPathComponent("library.json")
    }

    // MARK: - Adding and removing

    /// Imports a StarDict folder, `.ifo` file, or `.zip`. Safe to call with a
    /// URL handed over by `fileImporter`, whose security scope is opened here.
    func addDictionary(from url: URL) async throws {
        importProgress = 0

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let destination = Self.storageDirectory
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.importProgress = fraction }
        }

        do {
            let dictionary = try await Task.detached(priority: .userInitiated) {
                try StarDictImporter.import(from: url, into: destination, progress: report)
            }.value

            installed.append(dictionary)
            installed.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            enabledIDs.insert(dictionary.id)
            saveManifest()
            importProgress = nil
        } catch {
            importProgress = nil
            throw error
        }
    }

    // MARK: - Catalogue downloads

    /// True once this catalogue entry's file is in the library. Matched on the
    /// file name rather than the display name, which the reader can change.
    func isInstalled(_ item: CatalogDictionary) -> Bool {
        let fileName = DictionaryCatalog.fileName(for: item.id)
        return installed.contains { $0.fileURL.lastPathComponent == fileName }
    }

    func isDownloading(_ item: CatalogDictionary) -> Bool {
        downloadProgress[item.id] != nil
    }

    /// Fetches a catalogue dictionary and installs it, ready to search.
    ///
    /// The asset is already in the app's SQLite format, so it skips the
    /// StarDict importer entirely — download, inflate if gzipped, validate,
    /// move into place.
    func download(_ item: CatalogDictionary) async throws {
        guard !isInstalled(item), downloadProgress[item.id] == nil else { return }
        downloadProgress[item.id] = 0

        // Anything that leaves early must clear the progress row, or the row in
        // Settings is stuck on a spinner for the life of the process.
        defer { downloadProgress[item.id] = nil }

        let id = item.id
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                // The last tenth is the local install, which has no progress of
                // its own but is not instant for a hundred-megabyte file.
                self?.downloadProgress[id] = min(fraction, 1) * 0.9
            }
        }

        let downloaded = try await FileDownloader.download(
            from: item.url, expectedBytes: item.downloadBytes, progress: report)
        defer { try? FileManager.default.removeItem(at: downloaded) }

        downloadProgress[item.id] = 0.9
        let destination = Self.storageDirectory
            .appendingPathComponent(DictionaryCatalog.fileName(for: item.id))

        let summary = try await Task.detached(priority: .userInitiated) {
            try Self.installPreconverted(from: downloaded, at: destination)
        }.value

        let dictionary = InstalledDictionary(
            name: summary.bookname,
            language: summary.language ?? item.language,
            wordCount: summary.entryCount,
            fileURL: destination)

        // Re-downloading replaces the file in place, so any store still open on
        // the old copy has to be dropped or it keeps answering from stale pages.
        for stale in installed
        where stale.fileURL.lastPathComponent == destination.lastPathComponent {
            openStores[stale.id] = nil
            enabledIDs.remove(stale.id)
        }
        BrowseIndexStore.shared.discardIndex(forLexiconID: destination.lastPathComponent)
        installed.removeAll { $0.fileURL.lastPathComponent == destination.lastPathComponent }

        installed.append(dictionary)
        installed.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // Newly installed dictionaries search immediately, like an import.
        enabledIDs.insert(dictionary.id)
        saveManifest()
    }

    /// Inflates `source` if needed, checks it really is a dictionary, and puts
    /// it at `destination`. Nothing is written to the library until it passes.
    nonisolated static func installPreconverted(from source: URL,
                                                at destination: URL) throws -> PreconvertedDictionary.Summary {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)

        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent("staging-\(UUID().uuidString).sqlite")
        defer { try? fileManager.removeItem(at: staged) }

        if GzipFile.isGzip(source) {
            try GzipFile.decompress(from: source, to: staged)
        } else {
            try? fileManager.removeItem(at: staged)
            try fileManager.copyItem(at: source, to: staged)
        }

        let summary = try PreconvertedDictionary.validate(at: staged)

        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: staged, to: destination)
        return summary
    }

    func remove(_ dictionary: InstalledDictionary) {
        installed.removeAll { $0.id == dictionary.id }
        enabledIDs.remove(dictionary.id)
        openStores[dictionary.id] = nil
        BrowseIndexStore.shared.discardIndex(forLexiconID: Lexicon.installed(dictionary).id)
        try? FileManager.default.removeItem(at: dictionary.fileURL)
        saveManifest()
    }

    func rename(_ dictionary: InstalledDictionary, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = installed.firstIndex(where: { $0.id == dictionary.id })
        else { return }
        installed[index].name = trimmed
        saveManifest()
    }

    func isEnabled(_ dictionary: InstalledDictionary) -> Bool {
        enabledIDs.contains(dictionary.id)
    }

    func setEnabled(_ enabled: Bool, for dictionary: InstalledDictionary) {
        if enabled {
            enabledIDs.insert(dictionary.id)
        } else {
            enabledIDs.remove(dictionary.id)
        }
    }

    // MARK: - Lookup

    /// The enabled dictionaries with their open stores, in display order.
    /// Stores are opened once and cached for the life of the library.
    func stores() -> [(InstalledDictionary, ImportedDictionaryStore)] {
        var result: [(InstalledDictionary, ImportedDictionaryStore)] = []
        for dictionary in installed where enabledIDs.contains(dictionary.id) {
            if let cached = openStores[dictionary.id] {
                result.append((dictionary, cached))
            } else if let store = ImportedDictionaryStore(url: dictionary.fileURL) {
                openStores[dictionary.id] = store
                result.append((dictionary, store))
            }
        }
        return result
    }

    /// Definitions for `word` from every enabled dictionary that has one.
    func definitions(for word: String) -> [(dictionary: InstalledDictionary, definition: String)] {
        stores().compactMap { dictionary, store in
            guard let text = store.definition(for: word) else { return nil }
            return (dictionary, text)
        }
    }

    /// Merged suggestions across the enabled dictionaries, de-duplicated.
    func suggestions(matching query: String, limit: Int = 40) -> [String] {
        var seen = Set<String>()
        var results: [String] = []
        for (_, store) in stores() {
            for word in store.suggestions(matching: query, limit: limit) {
                if seen.insert(word.lowercased()).inserted { results.append(word) }
            }
        }
        return Array(results.prefix(limit))
    }

    // MARK: - Persistence

    private static func loadManifest() -> [InstalledDictionary] {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([InstalledDictionary].self, from: data)
        else { return [] }
        // The app container moves between installs, so the recorded absolute
        // path is only trustworthy for its file name.
        return decoded
            .map { $0.rebased(in: storageDirectory) }
            .filter(\.fileExists)
    }

    private func saveManifest() {
        guard let data = try? JSONEncoder().encode(installed) else { return }
        try? data.write(to: Self.manifestURL, options: .atomic)
    }

    private func persistEnabledIDs() {
        defaults.set(enabledIDs.map(\.uuidString), forKey: Self.enabledDefaultsKey)
    }
}
