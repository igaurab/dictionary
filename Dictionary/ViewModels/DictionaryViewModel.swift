import SwiftUI
import Combine

/// Which "dictionary source" is displayed, mirroring the source bar at the
/// top of an entry in the macOS Dictionary app (All / Dictionary / Thesaurus).
enum DictionarySource: String, CaseIterable, Identifiable {
    case all = "All"
    case dictionary = "Dictionary"
    case thesaurus = "Thesaurus"
    var id: String { rawValue }
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
            ImportedDefinition(dictionaryName: $0.dictionary.name, definition: $0.definition)
        }

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
    let definition: String
    var id: String { dictionaryName + "\u{0000}" + definition }
}
