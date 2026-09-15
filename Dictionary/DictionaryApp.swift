import SwiftUI
import CoreSpotlight

@main
struct DictionaryApp: App {
    @StateObject private var model = DictionaryViewModel()
    @StateObject private var favorites = FavoritesStore()

    init() {
        AppFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(favorites)
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
