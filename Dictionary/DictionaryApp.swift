import SwiftUI
import CoreSpotlight

@main
struct DictionaryApp: App {
    @StateObject private var model = DictionaryViewModel()
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var library = DictionaryLibrary.shared

    init() {
        AppFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(favorites)
                .environmentObject(library)
                .task {
                    // Utility priority and detached: building the index must
                    // never make the first search feel slow.
                    await Task.detached(priority: .utility) {
                        await SpotlightIndexer.indexIfNeeded()
                    }.value
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let word = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
                    else { return }
                    model.lookUp(word)
                }
        }
    }
}
