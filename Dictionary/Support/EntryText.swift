import Foundation

/// Reads the plain-text entries of downloaded and imported dictionaries.
///
/// The build scripts in `scripts/` shape every definition the same way: blocks
/// separated by a blank line, each opening with a part-of-speech line and
/// followed by numbered senses. That shape is enough to tell a real entry from
/// a bot-generated inflected form, and to pull out a heading and a first sense
/// for a flashcard.
enum EntryText {

    // MARK: - Inflected forms

    /// Headings of blocks that only point at another word: "Troisième personne
    /// du pluriel de…". The Wiktionary editions are mostly these — three in four
    /// Spanish entries — which is what makes "courais" resolve, but a paper
    /// dictionary never lists them, and neither should browsing or flashcards.
    private static let inflectionPrefixes: [[UInt8]] = [
        // Wikcionario
        "forma verbal", "forma adjetiva", "forma sustantiva", "forma de participio",
        // Wiktionary (Deutsch)
        "Deklinierte Form", "Konjugierte Form", "Dekliniertes Gerundivum",
        "Partizip I", "Komparativ", "Superlativ", "Erweiterter Infinitiv",
    ].map { Array($0.utf8) }

    /// Wiktionnaire marks every inflection block this way: "verbe (flexion)".
    private static let inflectionMarker = Array("(flexion)".utf8)

    /// True when every block of the definition is an inflected form. A headword
    /// with a real sense anywhere — "porte" is a noun as well as a form of
    /// "porter" — is kept.
    static func isInflectionOnly(_ definition: String) -> Bool {
        var text = definition
        return text.withUTF8 { buffer in
            guard let base = buffer.baseAddress else { return false }
            return isInflectionOnly(base, count: buffer.count)
        }
    }

    /// The same test over raw UTF-8, so building a browse index can run it on
    /// two million SQLite rows without making a Swift string of each definition.
    static func isInflectionOnly(_ base: UnsafePointer<UInt8>, count: Int) -> Bool {
        guard count > 0 else { return false }
        var start = 0
        while start < count {
            let remaining = count - start
            let lineEnd = memchr(base + start, Int32(UInt8(ascii: "\n")), remaining)
                .map { UnsafePointer<UInt8>($0.assumingMemoryBound(to: UInt8.self)) - base }
                ?? count
            if !isInflectionHeading(base + start, count: lineEnd - start) { return false }

            guard let separator = memmem(base + lineEnd, count - lineEnd, "\n\n", 2) else {
                return true
            }
            start = UnsafePointer<UInt8>(separator.assumingMemoryBound(to: UInt8.self)) - base + 2
            while start < count, base[start] == UInt8(ascii: "\n") { start += 1 }
        }
        return true
    }

    private static func isInflectionHeading(_ line: UnsafePointer<UInt8>, count: Int) -> Bool {
        if inflectionMarker.withUnsafeBufferPointer({
            memmem(line, count, $0.baseAddress, $0.count) != nil
        }) {
            return true
        }
        return inflectionPrefixes.contains { prefix in
            prefix.count <= count && memcmp(line, prefix, prefix.count) == 0
        }
    }

    // MARK: - Flashcards

    /// A heading such as "nom commun" or "वि. [सं.]" and the first sense under
    /// it, or nil when the text has nothing that would fit on a card.
    static func card(from definition: String) -> (heading: String, sense: String)? {
        let blocks = definition
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let block = blocks.first(where: { !isInflectionOnly($0) }) ?? blocks.first else {
            return nil
        }

        let lines = block
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }

        // A short first line over more text is a heading; anything else is a
        // sense on its own, which is how free-form StarDict entries read.
        let heading: String
        let sense: String
        if lines.count >= 2, first.count <= 48 {
            heading = strippingNumber(first)
            sense = strippingNumber(lines[1])
        } else {
            heading = ""
            sense = strippingNumber(first)
        }
        guard !sense.isEmpty else { return nil }
        return (heading, truncated(sense))
    }

    /// "1. ", "१. ", "(१) " — sense numbers in either script.
    private static func strippingNumber(_ line: String) -> String {
        guard let range = line.range(of: #"^\(?[0-9०-९]+[.)]\s*"#,
                                     options: .regularExpression) else { return line }
        return String(line[range.upperBound...])
    }

    /// Some Hindi senses run to a paragraph of commentary, which would push the
    /// card off the screen. Cut at a sentence end where there is one.
    private static func truncated(_ text: String, limit: Int = 260) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        if let stop = head.lastIndex(where: { "।.;".contains($0) }),
           head.distance(from: head.startIndex, to: stop) > limit / 2 {
            return String(head[...stop])
        }
        return head.trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}
