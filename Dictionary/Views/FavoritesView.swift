import SwiftUI

/// Saved words, presented as a sheet alongside Recent Searches.
///
/// The word list is the whole screen: no icons, no counts, no artwork — the
/// same restraint as `HistoryView`.
struct FavoritesView: View {
    /// The sheet doesn't own a `DictionaryViewModel`; the presenter decides what
    /// looking a word up means (and usually dismisses the sheet first).
    private let onSelect: (String) -> Void

    @EnvironmentObject private var favorites: FavoritesStore
    @Environment(\.dismiss) private var dismiss

    init(onSelect: @escaping (String) -> Void) {
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            Group {
                if favorites.words.isEmpty {
                    Text("Words you save will appear here.")
                        .font(.roboto(15))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(favorites.words, id: \.self) { word in
                            Button {
                                onSelect(word)
                                dismiss()
                            } label: {
                                Text(word)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .onDelete { offsets in
                            favorites.remove(atOffsets: offsets)
                        }
                    }
                }
            }
            .navigationTitle("Saved Words")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", role: .destructive) {
                        favorites.removeAll()
                    }
                    .disabled(favorites.words.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    FavoritesView { _ in }
        .environmentObject(FavoritesStore())
}
