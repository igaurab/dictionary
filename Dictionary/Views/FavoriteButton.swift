import SwiftUI

/// The save control for the word on screen, sitting in the entry's toolbar
/// beside the Back / Forward chevrons.
///
/// It reads as part of the entry's controls rather than floating over the
/// definition text. The heart is the one place the accent colour is allowed to
/// appear in an entry.
struct FavoriteButton: View {
    let word: String

    @EnvironmentObject private var favorites: FavoritesStore

    var body: some View {
        let saved = favorites.isFavorite(word)
        Button {
            favorites.toggle(word)
        } label: {
            Label(saved ? "Remove from Saved Words" : "Save Word",
                  systemImage: saved ? "heart.fill" : "heart")
        }
        .tint(saved ? Color.accentColor : Color.secondary)
        // A quiet state flip rather than a drawn-out animation.
        .animation(.easeInOut(duration: 0.15), value: saved)
    }
}
