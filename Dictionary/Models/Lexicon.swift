import Foundation

/// A dictionary the reader can leaf through or draw flashcards from: the
/// bundled WordNet, or one they downloaded or imported.
enum Lexicon: Identifiable, Hashable, Sendable {
    case wordNet
    case installed(InstalledDictionary)

    /// Stable across launches and renames: an installed dictionary's file name
    /// never changes, which is what persisted choices are keyed on.
    var id: String {
        switch self {
        case .wordNet: return "wordnet"
        case .installed(let dictionary): return dictionary.fileURL.lastPathComponent
        }
    }

    /// The full name, for titles.
    var name: String {
        switch self {
        case .wordNet: return "WordNet 3.1"
        case .installed(let dictionary): return dictionary.name
        }
    }

    /// The short name, for chips and menus - "नेपाली" rather than "नेपाली
    /// बृहत् शब्दकोश", matching the source bar.
    var label: String {
        switch self {
        case .wordNet: return "English"
        case .installed(let dictionary):
            let language = dictionary.language ?? ""
            return language.isEmpty ? dictionary.name : language
        }
    }

    /// The SQLite file behind it.
    var fileURL: URL? {
        switch self {
        case .wordNet: return Bundle.main.url(forResource: "WordNet", withExtension: "sqlite")
        case .installed(let dictionary): return dictionary.fileURL
        }
    }
}

extension DictionaryLibrary {
    /// WordNet first, then every installed dictionary that is switched on.
    /// Switched-off ones are left out because a word tapped while browsing is
    /// looked up across the enabled dictionaries only, and would come up empty.
    var lexicons: [Lexicon] {
        [.wordNet] + installed.filter(isEnabled).map(Lexicon.installed)
    }
}
