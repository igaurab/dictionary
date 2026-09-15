import SwiftUI
import Combine

/// Which dictionary the entry is showing, mirroring the source bar at the top
/// of an entry in the macOS Dictionary app.
///
/// macOS lists every installed dictionary there, not a fixed three, which is
/// what this needs to do too: "Thesaurus" is meaningless for a Nepali entry,
/// and a reader with several languages installed wants to see which one a
/// definition came from and to narrow to it.
enum DictionarySource: Hashable, Identifiable {
    case all
    /// WordNet's definitions and its synonym/antonym view.
    case dictionary
    case thesaurus
    /// A downloaded or imported dictionary, identified by its own name.
    case imported(name: String, label: String)

    var label: String {
        switch self {
        case .all: return "All"
        case .dictionary: return "Dictionary"
        case .thesaurus: return "Thesaurus"
        case .imported(_, let label): return label
        }
    }

    var id: String {
        switch self {
        case .all: return "all"
        case .dictionary: return "dictionary"
        case .thesaurus: return "thesaurus"
        case .imported(let name, _): return "imported:\(name)"
        }
    }

    /// True when this source should show the given imported dictionary.
    func shows(importedName: String) -> Bool {
        switch self {
        case .all: return true
        case .imported(let name, _): return name == importedName
        case .dictionary, .thesaurus: return false
        }
    }

    /// True when this source should show WordNet's own sections.
    var showsWordNet: Bool {
        switch self {
        case .all, .dictionary, .thesaurus: return true
        case .imported: return false
        }
    }
}

@MainActor
final class DictionaryViewModel: ObservableObject {
    private let store = DictionaryStore.shared
    private let library = DictionaryLibrary.shared

    // MARK: Search
    @Published var searchText = ""
    @Published var suggestions: [String] = []
    /// Drives `.searchable(isPresented:)`, so a `dictionary://search` tap from
    /// the Home Screen widget can put the keyboard in the field.
    @Published var isSearchPresented = false

    // MARK: Current entry + back/forward history (like Go > Back/Forward on macOS)
    @Published private(set) var currentLookup: LookupResult?
    @Published private(set) var currentTerm: String?
    /// Definitions for the current term from imported StarDict dictionaries,
    /// shown alongside (or instead of) the bundled WordNet entry.
    @Published private(set) var importedEntries: [ImportedDefinition] = []
    private var backStack: [String] = []
    private var forwardStack: [String] = []

    // MARK: Preferences
    @Published var source: DictionarySource = .all
    @Published var textScale: Double {
        didSet { UserDefaults.standard.set(textScale, forKey: "textScale") }
    }
    @Published var recents: [String] {
        didSet { UserDefaults.standard.set(recents, forKey: "recentLookups") }
    }
    /// Off by default: the macOS Dictionary app opens on an empty page, and a
    /// list of past lookups on the home screen reads as clutter.
    @Published var showRecentsOnHome: Bool {
        didSet { UserDefaults.standard.set(showRecentsOnHome, forKey: "showRecentsOnHome") }
    }

    private var searchTask: Task<Void, Never>?

    init() {
        recents = UserDefaults.standard.stringArray(forKey: "recentLookups") ?? []
        showRecentsOnHome = UserDefaults.standard.bool(forKey: "showRecentsOnHome")
        let storedScale = UserDefaults.standard.double(forKey: "textScale")
        textScale = storedScale == 0 ? 1.0 : storedScale
    }

    /// Shown on the empty page, the way macOS Dictionary names the dictionary
    /// it is about to search.
    var activeDictionaryName: String { "WordNet 3.1" }

    /// The sources the word on screen actually has, so the bar never offers a
    /// tab that would open an empty page.
    var availableSources: [DictionarySource] {
        var sources: [DictionarySource] = [.all]
        if let lookup = currentLookup {
            let entries: [WordEntry]
            switch lookup {
            case .found(let entry): entries = [entry]
            case .redirected(_, let found): entries = found
            case .notFound: entries = []
            }
            if !entries.isEmpty {
                sources.append(.dictionary)
                if entries.contains(where: \.hasThesaurusContent) {
                    sources.append(.thesaurus)
                }
            }
        }
        for imported in importedEntries {
            sources.append(.imported(name: imported.dictionaryName, label: imported.tabLabel))
        }
        // A lone "All" tab is just a label; the bar hides itself instead.
        return sources.count > 1 ? sources : []
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    var hasEntry: Bool { currentTerm != nil }

    // MARK: - Search

    func searchTextChanged() {
        searchTask?.cancel()
        let query = searchText
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            suggestions = []
            return
        }
        searchTask = Task { [store, library] in
            var results = store.suggestions(matching: query)
            // Imported dictionaries are searched too, so a word that only
            // exists in an added language still turns up.
            var seen = Set(results.map { $0.lowercased() })
            for word in library.suggestions(matching: query) where seen.insert(word.lowercased()).inserted {
                results.append(word)
            }
            if !Task.isCancelled {
                self.suggestions = results
            }
        }
    }

    /// Look up a word, pushing the previous entry onto the back stack.
    func lookUp(_ term: String, recordHistory: Bool = true) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if recordHistory, let current = currentTerm,
           current.lowercased() != trimmed.lowercased() {
            backStack.append(current)
            forwardStack.removeAll()
        }
        performLookup(trimmed)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let current = currentTerm { forwardStack.append(current) }
        performLookup(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current = currentTerm { backStack.append(current) }
        performLookup(next)
    }

    func lookUpRandomWord() {
        if let word = store.randomWord() {
            lookUp(word)
        }
    }

    func closeEntry() {
        currentTerm = nil
        currentLookup = nil
        importedEntries = []
        backStack.removeAll()
        forwardStack.removeAll()
    }

    func clearRecents() {
        recents.removeAll()
    }

    // MARK: - Private

    private func performLookup(_ term: String) {
        let result = store.lookup(term)
        currentTerm = term
        currentLookup = result
        importedEntries = library.definitions(for: term).map {
            let language = $0.dictionary.language ?? ""
            return ImportedDefinition(
                dictionaryName: $0.dictionary.name,
                tabLabel: language.isEmpty ? $0.dictionary.name : language,
                definition: $0.definition)
        }
        // A source picked for the previous word may not exist for this one.
        if !availableSources.contains(source) { source = .all }

        // A word absent from WordNet but present in an imported dictionary is
        // still a hit, and belongs in recents.
        if case .notFound = result, importedEntries.isEmpty { return }
        let display = displayName(for: result) ?? term
        recents.removeAll { $0.lowercased() == display.lowercased() }
        recents.insert(display, at: 0)
        if recents.count > 100 {
            recents.removeLast(recents.count - 100)
        }
    }

    private func displayName(for result: LookupResult) -> String? {
        switch result {
        case .found(let entry): return entry.word
        case .redirected(let from, _): return from
        case .notFound: return currentTerm
        }
    }
}


/// One imported dictionary's definition of the current headword.
struct ImportedDefinition: Identifiable, Equatable, Hashable {
    let dictionaryName: String
    /// The short name for the source bar - "नेपाली" reads better on a tab than
    /// "नेपाली बृहत् शब्दकोश".
    let tabLabel: String
    let definition: String
    var id: String { dictionaryName + "\u{0000}" + definition }
}
