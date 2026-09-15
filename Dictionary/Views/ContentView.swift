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
                VStack(spacing: 0) {
                    SourceBar(resultCount: 0)
                    Divider()
                    Text("No entries found for \u{201C}\(model.searchText)\u{201D}")
                        .font(.roboto(15))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 28)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            } else {
                // The source bar rides above the results, as it does on macOS,
                // so the top of the screen isn't blank while you search.
                VStack(spacing: 0) {
                    SourceBar(resultCount: model.suggestions.count)
                    Divider()
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
        }
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

    @ViewBuilder
    private var emptySearchState: some View {
        if model.showRecentsOnHome && !model.recents.isEmpty {
            List {
                Section("Recent") {
                    ForEach(model.recents.prefix(25), id: \.self) { word in
                        Button {
                            model.lookUp(word)
                        } label: {
                            Text(word)
                        }
                        // Recents are a quiet backdrop to the search field, not
                        // the point of the screen: smaller and grey rather than
                        // full-size accent-coloured rows.
                        .buttonStyle(.plain)
                        .font(.roboto(15))
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
        } else {
            emptyPage("Type a word to look up in\u{2026}")
        }
    }

    /// The macOS Dictionary app's empty page: no artwork, just the prompt and
    /// the name of the dictionary being searched, centred and grey.
    private func emptyPage(_ prompt: String) -> some View {
        VStack(spacing: 22) {
            Text(prompt)
                .font(.roboto(15))
            Text(model.activeDictionaryName)
                .font(.roboto(19))
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            emptyPage("Type a word to look up in\u{2026}")
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(DictionaryViewModel())
}
