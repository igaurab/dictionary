import SwiftUI

/// The macOS Dictionary app's empty page: no artwork, just the prompt and the
/// name of the dictionary being searched, grey and pinned near the top.
struct EmptyPage: View {
    @EnvironmentObject private var model: DictionaryViewModel

    let prompt: String
    /// The empty page names the dictionary; a "no results" message speaks for
    /// itself and doesn't.
    var showsDictionaryName = true

    var body: some View {
        VStack(spacing: 22) {
            Text(prompt)
                .font(.roboto(15))
            if showsDictionaryName {
                Text(model.activeDictionaryName)
                    .font(.roboto(19))
            }
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Everything the sidebar shows beneath the search field.
///
/// This is deliberately a separate view rather than a computed property on
/// ContentView: `\.isSearching` is only published to views *inside* the
/// searchable modifier, and it is what lets tapping the search field bring up
/// recents before a single character is typed.
struct SidebarBody: View {
    @EnvironmentObject private var model: DictionaryViewModel
    @Environment(\.isSearching) private var isSearching

    private var isQueryEmpty: Bool {
        model.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        if !isQueryEmpty {
            if model.suggestions.isEmpty {
                VStack(spacing: 0) {
                    SourceBar(resultCount: 0)
                    Divider()
                    EmptyPage(prompt: "No entries found for \u{201C}\(model.searchText)\u{201D}",
                              showsDictionaryName: false)
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
        } else if !model.recents.isEmpty && (isSearching || model.showRecentsOnHome) {
            // Tapping the field with nothing typed is a good moment to offer
            // what you looked up last, the way Safari offers recent tabs.
            recents
        } else {
            EmptyPage(prompt: "Type a word to look up in\u{2026}")
        }
    }

    /// Recents are a quiet backdrop to the search field, not the point of the
    /// screen: smaller and grey rather than accent-coloured rows.
    private var recents: some View {
        List {
            Section("Recent") {
                ForEach(model.recents.prefix(25), id: \.self) { word in
                    Button {
                        model.lookUp(word)
                    } label: {
                        Text(word)
                    }
                    .buttonStyle(.plain)
                    .font(.roboto(15))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
