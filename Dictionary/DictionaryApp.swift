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
                .onOpenURL { url in
                    open(url)
                }
        }
    }

    /// Resolves a `dictionary://` URL, the scheme the Home Screen widgets tap
    /// into. (`dictlookup://`, used for word links inside an entry, never
    /// leaves the process and is handled in `ContentView`.)
    private func open(_ url: URL) {
        guard url.scheme == WidgetLink.scheme else { return }
        switch url.host {
        case WidgetLink.wordHost:
            guard let word = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "w" })?.value,
                  !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            model.lookUp(word)
        case WidgetLink.searchHost:
            // Pop any open entry first, otherwise the search field is off screen.
            model.closeEntry()
            model.isSearchPresented = true
        default:
            break
        }
    }
}

/// The widget-facing URL scheme. Mirrored by `WidgetDeepLink` in the widget
/// extension, which is a separate module and can't share this type.
private enum WidgetLink {
    static let scheme = "dictionary"
    static let wordHost = "word"
    static let searchHost = "search"
}
