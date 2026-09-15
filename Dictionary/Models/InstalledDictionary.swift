import Foundation

/// A StarDict dictionary the user imported, after conversion to the app's own
/// SQLite format.
///
/// `fileURL` is persisted, but the app container path changes on reinstall and
/// on some OS upgrades, so `DictionaryLibrary` re-bases it against the current
/// storage directory when it loads the manifest. Only the file name is durable.
struct InstalledDictionary: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    var name: String
    var language: String?
    var wordCount: Int
    var fileURL: URL
    var dateAdded: Date

    init(id: UUID = UUID(), name: String, language: String? = nil,
         wordCount: Int, fileURL: URL, dateAdded: Date = Date()) {
        self.id = id
        self.name = name
        self.language = language
        self.wordCount = wordCount
        self.fileURL = fileURL
        self.dateAdded = dateAdded
    }

    /// A copy whose file is looked for in `directory`, keeping the stored name.
    func rebased(in directory: URL) -> InstalledDictionary {
        var copy = self
        copy.fileURL = directory.appendingPathComponent(fileURL.lastPathComponent)
        return copy
    }

    var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }
}
