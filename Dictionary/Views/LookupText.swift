import SwiftUI

/// Internal URL scheme used to make every word in an entry tappable,
/// mirroring the macOS Dictionary behavior of looking up any word you
/// double-click inside an entry.
enum LookupLink {
    static let scheme = "dictlookup"

    static func url(for word: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "word"
        components.queryItems = [URLQueryItem(name: "w", value: word)]
        return components.url
    }

    static func word(from url: URL) -> String? {
        guard url.scheme == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        return components.queryItems?.first(where: { $0.name == "w" })?.value
    }
}

extension AttributedString {
    /// Builds text in which every word is a tap-to-look-up link, rendered in
    /// the given style so it reads as ordinary text rather than a hyperlink.
    static func lookupText(
        _ text: String,
        color: Color = .primary
    ) -> AttributedString {
        var result = AttributedString()
        var wordBuffer = ""

        func flushWord() {
            guard !wordBuffer.isEmpty else { return }
            var attributed = AttributedString(wordBuffer)
            let lookup = wordBuffer.trimmingCharacters(in: .punctuationCharacters)
            if !lookup.isEmpty, let url = LookupLink.url(for: lookup) {
                attributed.link = url
            }
            attributed.foregroundColor = color
            result += attributed
            wordBuffer = ""
        }

        for character in text {
            if character.isWhitespace {
                flushWord()
                var space = AttributedString(String(character))
                space.foregroundColor = color
                result += space
            } else {
                wordBuffer.append(character)
            }
        }
        flushWord()
        return result
    }

    /// A comma-separated run of tappable words (for synonym/antonym lists).
    static func lookupWordList(
        _ words: [String],
        color: Color = .primary,
        separator: String = ", "
    ) -> AttributedString {
        var result = AttributedString()
        for (index, word) in words.enumerated() {
            if index > 0 {
                var sep = AttributedString(separator)
                sep.foregroundColor = .secondary
                result += sep
            }
            var attributed = AttributedString(word)
            if let url = LookupLink.url(for: word) {
                attributed.link = url
            }
            attributed.foregroundColor = color
            result += attributed
        }
        return result
    }
}
