import Foundation

/// One dictionary offered for download in Settings.
///
/// The file behind `url` is already in the app's own SQLite format, so it is
/// installed directly and never goes through `StarDictImporter`.
struct CatalogDictionary: Identifiable, Hashable, Sendable {
    /// Stable across releases: it names the installed file, which is how the
    /// app knows a catalogue entry is already on disk.
    let id: String
    let name: String
    let language: String
    let entryCount: Int
    /// Size of the file as served, for the "23.5 MB" label and the truncation check.
    let downloadBytes: Int64
    let licence: String
    let summary: String
    let url: URL
}

enum DictionaryCatalog {

    // MARK: - ▼▼▼ THE ONE CONSTANT TO EDIT ▼▼▼
    //
    // Swap `url` for the GitHub Release asset URL once the release exists, e.g.
    //   https://github.com/<user>/dictionary/releases/download/dict-es-v1/es-wiktionary.sqlite.gz
    // and update `downloadBytes` to the asset's real size. Nothing else needs
    // to change: the installer sniffs gzip from the file's magic bytes, so the
    // same code works whether the asset is gzipped or raw.

    static let entries: [CatalogDictionary] = [
        CatalogDictionary(
            id: "es-wiktionary",
            name: "Wikcionario (Español)",
            language: "Español",
            entryCount: 814_879,
            downloadBytes: 26_708_305,
            licence: "CC BY-SA 4.0",
            summary: "Diccionario monolingüe: palabras españolas definidas en español.",
            url: URL(string: "https://github.com/igaurab/dictionary/releases/download/dictionaries-v1/es-wiktionary.sqlite.gz")!
        )
    ]

    // MARK: - ▲▲▲ END ▲▲▲

    /// The file name an installed catalogue dictionary takes, which is what
    /// makes "already installed" survive a rename or a reinstall.
    static func fileName(for id: String) -> String {
        "catalog-\(id).sqlite"
    }
}
