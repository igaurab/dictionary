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

    // Each file is built by a script in `scripts/` and published as a release
    // asset. `downloadBytes` is the size as served; the installer sniffs gzip
    // from the magic bytes, so the same code works gzipped or raw.
    //
    // Dictionary content keeps the licence of the project it came from, which
    // is why `licence` is shown next to every entry rather than buried in the
    // about screen.

    // Sizes here are the full editions, which include bot-generated inflected
    // forms - the entries that let "Häuser" and "courais" resolve at all.
    // Lemma-only builds of German and French exist as `*-lemmas.sqlite.gz`
    // assets in the same release (12.6 MB and 30.5 MB) if the download size
    // matters more than looking up a conjugated word; switching is a change of
    // `url`, `entryCount` and `downloadBytes` here and nothing else.

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
        ),
        CatalogDictionary(
            id: "de-wiktionary",
            name: "Wiktionary (Deutsch)",
            language: "Deutsch",
            entryCount: 959_164,
            downloadBytes: 47_138_602,
            licence: "CC BY-SA 4.0",
            summary: "Einsprachiges Wörterbuch: deutsche Wörter auf Deutsch erklärt, mit gebeugten Formen.",
            url: URL(string: "https://github.com/igaurab/dictionary/releases/download/dictionaries-v1/de-wiktionary.sqlite.gz")!
        ),
        CatalogDictionary(
            id: "fr-wiktionary",
            name: "Wiktionnaire (Français)",
            language: "Français",
            entryCount: 2_029_440,
            downloadBytes: 74_414_944,
            licence: "CC BY-SA 4.0",
            summary: "Dictionnaire monolingue : mots français définis en français, formes fléchies comprises.",
            url: URL(string: "https://github.com/igaurab/dictionary/releases/download/dictionaries-v1/fr-wiktionary.sqlite.gz")!
        ),
        CatalogDictionary(
            id: "hi-wiktionary",
            name: "हिन्दी विक्षनरी",
            language: "हिन्दी",
            entryCount: 165_231,
            downloadBytes: 16_418_640,
            licence: "CC BY-SA 4.0",
            summary: "एकभाषी शब्दकोश: हिन्दी शब्दों के अर्थ हिन्दी में। अधिकांश अर्थ हिन्दी शब्दसागर से।",
            url: URL(string: "https://github.com/igaurab/dictionary/releases/download/dictionaries-v1/hi-wiktionary.sqlite.gz")!
        ),
        CatalogDictionary(
            id: "ne-sabdakosh",
            name: "नेपाली बृहत् शब्दकोश",
            language: "नेपाली",
            entryCount: 123_371,
            downloadBytes: 7_492_246,
            licence: "नेपाल प्रज्ञा-प्रतिष्ठान · via yoshabdakosh (MIT)",
            summary: "एकभाषी शब्दकोश: नेपाली शब्दहरूको अर्थ नेपालीमै। नेपाल प्रज्ञा-प्रतिष्ठानको बृहत् शब्दकोशबाट।",
            url: URL(string: "https://github.com/igaurab/dictionary/releases/download/dictionaries-v1/ne-sabdakosh.sqlite.gz")!
        )
    ]

    // MARK: - ▲▲▲ END ▲▲▲

    /// The file name an installed catalogue dictionary takes, which is what
    /// makes "already installed" survive a rename or a reinstall.
    static func fileName(for id: String) -> String {
        "catalog-\(id).sqlite"
    }
}
