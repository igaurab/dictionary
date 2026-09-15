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
    /// The short name of the dictionary the card came from, such as "नेपाली".
    let dictionary: String

    func renumbered(_ id: Int) -> Flashcard {
        Flashcard(id: id, word: word, partOfSpeech: partOfSpeech, definition: definition,
                  example: example, dictionary: dictionary)
    }
}

/// Where a deck's words come from.
enum FlashcardSource: Equatable {
    /// The reader's own recent lookups, newest first.
    case recents
    /// A fresh draw from the dictionaries the reader picked.
    case random

    var title: String {
        switch self {
        case .recents: return "Flashcards"
        case .random: return "Random Flashcards"
        }
    }
}

/// A flashcard deck over words the reader has already met, or over random
/// headwords from one or more dictionaries.
///
/// A recents deck is built in `init`, because a few dozen indexed lookups are
/// quicker than the sheet's presentation animation. A random deck loads off the
/// main actor behind a spinner: a draw from a Wiktionary edition can take a
/// dozen tries per card to get past the inflected forms.
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
    /// The dictionaries a random deck draws from, never empty.
    @Published private(set) var lexicons: [Lexicon]

    let source: FlashcardSource
    private var drawTask: Task<Void, Never>?

    /// `lexicons` defaults to the reader's last choice for random decks.
    init(source: FlashcardSource, words: [String] = [], lexicons: [Lexicon]? = nil) {
        self.source = source
        let chosen = lexicons ?? Self.savedLexicons()
        self.lexicons = chosen.isEmpty ? [.wordNet] : chosen
        switch source {
        case .recents:
            let imported = DictionaryLibrary.shared.stores().map { dictionary, store in
                (label: Lexicon.installed(dictionary).label, store: store)
            }
            cards = Self.cards(for: Array(words.prefix(Self.recentsDeckLimit)), imported: imported)
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

    /// Name the dictionary on each card only when the deck mixes several.
    var showsDictionary: Bool {
        Set(cards.map(\.dictionary)).count > 1
    }

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
        cards = cards.shuffled().enumerated().map { offset, card in card.renumbered(offset) }
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

    /// Adds or removes a dictionary from a random deck and deals again. The
    /// last one can't be removed, or there would be nothing to draw from.
    func toggle(_ lexicon: Lexicon) {
        if let position = lexicons.firstIndex(of: lexicon) {
            guard lexicons.count > 1 else { return }
            lexicons.remove(at: position)
        } else {
            lexicons.append(lexicon)
        }
        UserDefaults.standard.set(lexicons.map(\.id), forKey: Self.savedLexiconsKey)
        draw()
    }

    // MARK: - Saved choice

    private static let savedLexiconsKey = "randomFlashcardDictionaries"

    /// The dictionaries picked last time that are still installed and on.
    static func savedLexicons() -> [Lexicon] {
        let available = DictionaryLibrary.shared.lexicons
        let saved = UserDefaults.standard.stringArray(forKey: savedLexiconsKey) ?? []
        let chosen = available.filter { saved.contains($0.id) }
        return chosen.isEmpty ? [.wordNet] : chosen
    }

    // MARK: - Deck construction

    /// Draws a random deck off the main actor. Every store is opened read-only
    /// and full-mutex, so reading them from another thread is safe.
    private func draw() {
        drawTask?.cancel()
        isLoading = true
        cards = []
        index = 0
        isRevealed = false
        let size = Self.randomDeckSize
        let lexicons = self.lexicons
        drawTask = Task { [weak self] in
            let drawn = await Task.detached(priority: .userInitiated) {
                FlashcardDeck.randomCards(from: lexicons, count: size)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.cards = drawn
            self.index = 0
            self.isRevealed = false
            self.isLoading = false
        }
    }

    /// Deals the dictionaries in turn, so twenty cards from English and Nepali
    /// are ten of each, then shuffles them together.
    nonisolated private static func randomCards(from lexicons: [Lexicon], count: Int) -> [Flashcard] {
        var stores: [String: ImportedDictionaryStore] = [:]
        for case .installed(let dictionary) in lexicons {
            stores[dictionary.fileURL.lastPathComponent] = ImportedDictionaryStore(url: dictionary.fileURL)
        }

        var cards: [Flashcard] = []
        var seen = Set<String>()
        for slot in 0..<count {
            let lexicon = lexicons[slot % lexicons.count]
            // Bounded, so a broken dictionary can't stall the deck. Forty tries
            // is enough for Wikcionario, where seven rows in eight are
            // inflected forms: a slot comes up empty less than 1% of the time.
            for _ in 0..<40 {
                let card: Flashcard?
                switch lexicon {
                case .wordNet:
                    card = DictionaryStore.shared.randomWord().flatMap { wordNetCard(for: $0) }
                case .installed:
                    card = stores[lexicon.id]?.randomEntry().flatMap {
                        importedCard(word: $0.word, definition: $0.definition, label: lexicon.label)
                    }
                }
                if let card, seen.insert(card.dictionary + "\u{0}" + card.word.lowercased()).inserted {
                    cards.append(card)
                    break
                }
            }
        }
        return cards.shuffled().enumerated().map { offset, card in card.renumbered(offset) }
    }

    /// Words resolved to a headword and its leading definition, dropping any
    /// that would show a blank back. Inflected forms resolve to their base
    /// ("went" -> "go"), which is also how duplicate recents collapse. A word
    /// WordNet doesn't know - a Nepali lookup, say - comes from the first
    /// installed dictionary that has it.
    nonisolated private static func cards(
        for words: [String],
        imported: [(label: String, store: ImportedDictionaryStore)]
    ) -> [Flashcard] {
        var seen = Set<String>()
        var cards: [Flashcard] = []
        for term in words {
            var card = wordNetCard(for: term)
            if card == nil {
                for (label, store) in imported {
                    if let definition = store.definition(for: term),
                       let found = importedCard(word: term, definition: definition, label: label) {
                        card = found
                        break
                    }
                }
            }
            guard let card, seen.insert(card.word.lowercased()).inserted else { continue }
            cards.append(card.renumbered(cards.count))
        }
        return cards
    }

    nonisolated private static func wordNetCard(for term: String) -> Flashcard? {
        guard let entry = entry(for: term), let sense = firstSense(of: entry) else { return nil }
        let definition = sense.definition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !definition.isEmpty else { return nil }
        return Flashcard(
            id: 0,
            word: entry.word,
            partOfSpeech: sense.partOfSpeech,
            definition: definition,
            example: sense.examples.first?.trimmingCharacters(in: .whitespacesAndNewlines),
            dictionary: Lexicon.wordNet.label
        )
    }

    /// Imported entries are free text, so the heading stands in for the part
    /// of speech. Entries that are only an inflected form are skipped: "second
    /// person plural of…" teaches nothing on a card.
    nonisolated private static func importedCard(word: String, definition: String,
                                                 label: String) -> Flashcard? {
        guard !EntryText.isInflectionOnly(definition),
              let card = EntryText.card(from: definition) else { return nil }
        return Flashcard(id: 0, word: word, partOfSpeech: card.heading,
                         definition: card.sense, example: nil, dictionary: label)
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
