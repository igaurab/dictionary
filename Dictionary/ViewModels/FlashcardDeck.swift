import Combine
import Foundation

/// One card: the headword on the front, its first definition on the back.
struct Flashcard: Identifiable, Equatable, Sendable {
    /// Position in the deck, which is what makes the card identifiable to
    /// SwiftUI — the same headword can reappear after a shuffle.
    let id: Int
    let word: String
    let partOfSpeech: String
    let definition: String
    /// At most one, as a hint on the back; a wall of examples defeats the card.
    let example: String?
}

/// Where a deck's words come from.
enum FlashcardSource: Equatable {
    /// The reader's own recent lookups, newest first.
    case recents
    /// A fresh draw from the dictionary at large.
    case random

    var title: String {
        switch self {
        case .recents: return "Flashcards"
        case .random: return "Random Flashcards"
        }
    }
}

/// A flashcard deck over words the reader has already met, or over random
/// headwords for browsing.
///
/// A recents deck is built in `init`, because a few dozen indexed lookups are
/// quicker than the sheet's presentation animation. A random deck is not: each
/// draw scans the word table, and twenty of them stall the animation for about
/// a third of a second, so those load off the main actor behind a spinner.
@MainActor
final class FlashcardDeck: ObservableObject {
    /// Enough for a sitting without turning the deck into a chore.
    static let randomDeckSize = 20
    /// Recents can run to a hundred; a deck that long never gets finished.
    static let recentsDeckLimit = 30

    @Published private(set) var cards: [Flashcard] = []
    /// May equal `cards.count`, which is what "reached the end" means.
    @Published private(set) var index = 0
    @Published private(set) var isRevealed = false
    /// True only while a random deck is being drawn.
    @Published private(set) var isLoading = false

    let source: FlashcardSource
    private let seedWords: [String]

    init(source: FlashcardSource, words: [String] = []) {
        self.source = source
        self.seedWords = words
        switch source {
        case .recents:
            cards = Self.cards(for: Array(words.prefix(Self.recentsDeckLimit)))
        case .random:
            draw()
        }
    }

    // MARK: - Reading

    var current: Flashcard? {
        cards.indices.contains(index) ? cards[index] : nil
    }

    var isEmpty: Bool { cards.isEmpty }
    var isAtEnd: Bool { !cards.isEmpty && index >= cards.count }
    var isLastCard: Bool { index == cards.count - 1 }

    /// "3 of 12", for the counter above the card.
    var position: String { "\(min(index + 1, cards.count)) of \(cards.count)" }

    // MARK: - Actions

    func flip() {
        guard current != nil, !isLoading else { return }
        isRevealed.toggle()
    }

    /// Advancing past the last card lands on the finished screen.
    func next() {
        guard index < cards.count else { return }
        index += 1
        isRevealed = false
    }

    func previous() {
        guard index > 0 else { return }
        index -= 1
        isRevealed = false
    }

    /// Reorders the cards already in hand and starts over.
    func shuffle() {
        cards = cards.shuffled().enumerated().map { offset, card in
            Flashcard(id: offset, word: card.word, partOfSpeech: card.partOfSpeech,
                      definition: card.definition, example: card.example)
        }
        index = 0
        isRevealed = false
    }

    /// Back to the first card. A random deck draws new words instead, because
    /// re-reading the same twenty is not what "random" promised.
    func restart() {
        switch source {
        case .random:
            draw()
        case .recents:
            index = 0
            isRevealed = false
        }
    }

    // MARK: - Deck construction

    /// Draws a random deck off the main actor. `DictionaryStore` is opened
    /// read-only and full-mutex, so reading it from another thread is safe.
    private func draw() {
        isLoading = true
        cards = []
        index = 0
        isRevealed = false
        let size = Self.randomDeckSize
        Task { [weak self] in
            let drawn = await Task.detached(priority: .userInitiated) {
                FlashcardDeck.cards(for: FlashcardDeck.randomWords(count: size))
            }.value
            guard let self else { return }
            self.cards = drawn
            self.index = 0
            self.isRevealed = false
            self.isLoading = false
        }
    }

    /// Words resolved to a headword and its leading definition, dropping any
    /// that would show a blank back. Inflected forms resolve to their base
    /// ("went" -> "go"), which is also how duplicate recents collapse.
    nonisolated private static func cards(for words: [String]) -> [Flashcard] {
        var seen = Set<String>()
        var cards: [Flashcard] = []
        for term in words {
            guard let entry = entry(for: term), let sense = firstSense(of: entry) else { continue }
            let definition = sense.definition.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !definition.isEmpty else { continue }
            guard seen.insert(entry.word.lowercased()).inserted else { continue }
            cards.append(Flashcard(
                id: cards.count,
                word: entry.word,
                partOfSpeech: sense.partOfSpeech,
                definition: definition,
                example: sense.examples.first?.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return cards
    }

    /// `randomWord()` draws with replacement, so the loop is bounded rather than
    /// trusting it to produce `count` distinct words.
    nonisolated private static func randomWords(count: Int) -> [String] {
        var words: [String] = []
        var seen = Set<String>()
        var attempts = 0
        while words.count < count, attempts < count * 4 {
            attempts += 1
            guard let word = DictionaryStore.shared.randomWord() else { break }
            if seen.insert(word.lowercased()).inserted { words.append(word) }
        }
        return words
    }

    /// The sense the entry screen leads with — `senses` arrives ordered by part
    /// of speech alphabetically, which would card "go" on its adjective sense.
    nonisolated private static func firstSense(of entry: WordEntry) -> WordSense? {
        entry.sensesByPartOfSpeech.first?.senses.first ?? entry.senses.first
    }

    nonisolated private static func entry(for term: String) -> WordEntry? {
        switch DictionaryStore.shared.lookup(term) {
        case .found(let entry): return entry
        case .redirected(_, let entries): return entries.first
        case .notFound: return nil
        }
    }
}
