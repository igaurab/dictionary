import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: DictionaryViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingHistory = false
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
    }

    // MARK: Sidebar — live search results, like the macOS Dictionary sidebar

    private var sidebar: some View {
        Group {
            if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                emptySearchState
            } else if model.suggestions.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            } else {
                List(model.suggestions, id: \.self) { word in
                    Button {
                        model.lookUp(word)
                    } label: {
                        Text(word)
                            .foregroundStyle(.primary)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Dictionary")
        .searchable(
            text: $model.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
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
                        model.lookUpRandomWord()
                    } label: {
                        Label("Random Word", systemImage: "dice")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    private var emptySearchState: some View {
        VStack(spacing: 20) {
            if model.recents.isEmpty {
                ContentUnavailableView(
                    "Dictionary",
                    systemImage: "character.book.closed",
                    description: Text("Search 147,000 words, entirely offline.")
                )
            } else {
                List {
                    Section("Recent") {
                        ForEach(model.recents.prefix(25), id: \.self) { word in
                            Button {
                                model.lookUp(word)
                            } label: {
                                Label(word, systemImage: "clock")
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
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
            ContentUnavailableView(
                "No Selection",
                systemImage: "character.book.closed",
                description: Text("Search for a word, or tap any word in an entry to look it up.")
            )
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(DictionaryViewModel())
}
