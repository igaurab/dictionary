import Foundation

/// The `dictionary://` URLs a widget tap hands to the app.
///
/// The app registers this scheme in its Info.plist and resolves these in
/// `DictionaryApp.onOpenURL`. (It's distinct from the app-internal
/// `dictlookup://` scheme, which never leaves the process.)
enum WidgetDeepLink {
    static let scheme = "dictionary"

    /// `dictionary://word?w=<word>` — opens the entry for that headword.
    static func word(_ word: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "word"
        components.queryItems = [URLQueryItem(name: "w", value: word)]
        return components.url
    }

    /// `dictionary://search` — opens the app with the search field focused.
    static var search: URL? {
        URL(string: "\(scheme)://search")
    }
}
