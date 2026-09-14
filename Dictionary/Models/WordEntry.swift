import Foundation

/// A complete dictionary entry for a single headword.
struct WordEntry: Identifiable, Equatable, Hashable {
    let id: Int64
    let word: String
    let pronunciation: String?
    let senses: [WordSense]

    /// Senses grouped by part of speech, in the canonical order the macOS
    /// Dictionary app uses (noun, verb, adjective, adverb).
    var sensesByPartOfSpeech: [PartOfSpeechGroup] {
        let order = ["noun", "verb", "adjective", "adverb"]
        var groups: [String: [WordSense]] = [:]
        for sense in senses {
            groups[sense.partOfSpeech, default: []].append(sense)
        }
        return order.compactMap { pos in
            guard let group = groups[pos] else { return nil }
            return PartOfSpeechGroup(
                partOfSpeech: pos,
                senses: group.sorted { $0.senseNumber < $1.senseNumber }
            )
        }
    }

    var hasThesaurusContent: Bool {
        senses.contains { !$0.synonyms.isEmpty || !$0.antonyms.isEmpty }
    }
}

/// All senses of an entry that share a part of speech.
struct PartOfSpeechGroup: Identifiable, Equatable, Hashable {
    let partOfSpeech: String
    let senses: [WordSense]
    var id: String { partOfSpeech }
}

/// One numbered sense of a word within a part of speech.
struct WordSense: Identifiable, Equatable, Hashable {
    let id: Int64
    let partOfSpeech: String
    let senseNumber: Int
    let definition: String
    let examples: [String]
    let synonyms: [String]
    let antonyms: [String]
}

/// The result of looking a word up, including redirects through
/// inflected forms ("went" -> "go").
enum LookupResult: Equatable {
    case found(WordEntry)
    /// The searched term is an inflected form of one or more base words.
    case redirected(from: String, entries: [WordEntry])
    case notFound(suggestions: [String])
}
