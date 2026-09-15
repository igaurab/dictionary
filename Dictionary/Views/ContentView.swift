import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: DictionaryViewModel
    @EnvironmentObject private var favorites: FavoritesStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingHistory = false
    @State private var showingFavorites = false
    @State private var showingQuiz = false
    @State private var showingFlashcards = false
    @State private var showingRandomFlashcards = false
    @State private var showingSettings = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    /// On iPhone the split view collapses to a single column, so the entry has
    /// to be pushed onto a stack; on iPad it stays in the detail column.
    private var isCompact: Bool { horizontalSizeClass == .compact }

    /// Mirrors the current entry as a one-element navigation path, so looking a
    /// word up pushes the entry and popping it clears the entry. Tapping a word
    /// inside an entry swaps the destination in place, which keeps the app's own
    /// Back / Forward chevrons as the history control.
    private var path: Binding<[String]> {
        Binding(
            get: { model.currentTerm.map { [$0] } ?? [] },
            set: { if $0.isEmpty { model.closeEntry() } }
        )
    }

    var body: some View {
        Group {
            if isCompact {
                NavigationStack(path: path) {
                    sidebar
                        .navigationDestination(for: String.self) { _ in
                            detail
                        }
                }
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar
                } detail: {
                    detail
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let word = LookupLink.word(from: url) {
                model.lookUp(word)
                return .handled
            }
            return .systemAction
        })
        .sheet(isPresented: $showingHistory) {
            HistoryView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingFavorites) {
            FavoritesView { model.lookUp($0) }
        }
        .sheet(isPresented: $showingFlashcards) {
            // Same pool as the quiz: words you kept, then words you looked up.
            FlashcardsView(source: .recents, words: favorites.words + model.recents)
        }
        .sheet(isPresented: $showingRandomFlashcards) {
            FlashcardsView(source: .random)
        }
        .sheet(isPresented: $showingQuiz) {
            // Quizzing on words you actually looked up is the point; favourites
            // are the ones you deliberately kept, so they count double here.
            QuizView(pool: favorites.words + model.recents)
        }
    }

    // MARK: Sidebar — live search results, like the macOS Dictionary sidebar

    private var sidebar: some View {
        // SidebarBody is a child of the searchable modifier, which is what lets
        // it read \.isSearching and offer recents the moment the field is tapped.
        SidebarBody()
        .navigationTitle("Dictionary")
        // .toolbar puts the field in the bottom bar on iPhone, within thumb
        // reach, the way the iOS 26 system apps place search.
        .searchable(
            text: $model.searchText,
            placement: .toolbar,
            prompt: "Search"
        )
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onSubmit(of: .search) {
            model.lookUp(model.searchText)
        }
        .onChange(of: model.searchText) {
            model.searchTextChanged()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "textformat.size")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingHistory = true
                    } label: {
                        Label("Recent Searches", systemImage: "clock")
                    }
                    Button {
                        showingFavorites = true
                    } label: {
                        Label("Saved Words", systemImage: "heart")
                    }
                    Button {
                        showingQuiz = true
                    } label: {
                        Label("Quiz", systemImage: "checkmark.circle")
                    }
                    Button {
                        showingFlashcards = true
                    } label: {
                        Label("Flashcards", systemImage: "rectangle.on.rectangle")
                    }
                    Divider()
                    Button {
                        model.lookUpRandomWord()
                    } label: {
                        Label("Random Word", systemImage: "dice")
                    }
                    Button {
                        showingRandomFlashcards = true
                    } label: {
                        Label("Random Flashcards", systemImage: "rectangle.on.rectangle.angled")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: Detail — the entry itself

    @ViewBuilder
    private var detail: some View {
        if let lookup = model.currentLookup, let term = model.currentTerm {
            LookupResultView(term: term, result: lookup)
                .id(term)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        FavoriteButton(word: term)

                        Button {
                            model.goBack()
                        } label: {
                            Label("Back", systemImage: "chevron.backward")
                        }
                        .disabled(!model.canGoBack)

                        Button {
                            model.goForward()
                        } label: {
                            Label("Forward", systemImage: "chevron.forward")
                        }
                        .disabled(!model.canGoForward)
                    }
                }
        } else {
            EmptyPage(prompt: "Type a word to look up in\u{2026}")
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(DictionaryViewModel())
}
