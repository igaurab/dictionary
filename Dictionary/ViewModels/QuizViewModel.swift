import Combine
import Foundation

/// One multiple-choice question: a single definition and four headwords, exactly
/// one of which that definition belongs to.
struct QuizQuestion: Identifiable, Equatable {
    /// Position in the round, which is also what makes the question identifiable
    /// to SwiftUI — headwords could otherwise repeat across rounds.
    let id: Int
    let answer: String
    let partOfSpeech: String
    let definition: String
    let options: [String]
}

enum QuizState: Equatable {
    /// Too few of the reader's words had a usable definition to build a round.
    case needsMoreWords(have: Int, need: Int)
    /// `selected` is nil until the reader answers, and is what "revealed" means.
    case question(QuizQuestion, index: Int, total: Int, selected: String?)
    case finished(score: Int, total: Int)
}

/// A vocabulary quiz built entirely from words the reader has already met —
/// recents and favourites — so it never tests dictionary trivia.
@MainActor
final class QuizViewModel: ObservableObject {
    static let questionsPerRound = 10
    static let optionCount = 4
    /// Four options means three distractors, so a round needs four words.
    static let minimumPoolSize = 4

    @Published private(set) var state: QuizState =
        .needsMoreWords(have: 0, need: QuizViewModel.minimumPoolSize)
    @Published private(set) var score = 0

    private let pool: [String]
    /// Set only by tests and the debug harness; a real round reseeds on restart.
    private let fixedSeed: UInt64?
    private var questions: [QuizQuestion] = []
    private var index = 0
    private var selected: String?

    init(pool: [String], seed: UInt64? = nil) {
        self.pool = pool
        self.fixedSeed = seed
        start(seed: seed ?? UInt64.random(in: UInt64.min...UInt64.max))
    }

    // MARK: - Actions

    /// Ignored once the answer is revealed, so a second tap can't change a score.
    func answer(_ option: String) {
        guard case .question(let question, _, _, nil) = state else { return }
        selected = option
        if option.caseInsensitiveCompare(question.answer) == .orderedSame {
            score += 1
        }
        updateState()
    }

    func next() {
        guard case .question = state, selected != nil else { return }
        index += 1
        selected = nil
        updateState()
    }

    /// A fresh round from the same pool: new words, new order, new option order.
    func restart() {
        start(seed: fixedSeed ?? UInt64.random(in: UInt64.min...UInt64.max))
    }

    // MARK: - Round construction

    /// Everything is built up front, and the shuffles all draw from one seeded
    /// generator, so a round's questions and option order stay put no matter how
    /// often the view re-renders.
    private func start(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let usable = Self.usableWords(in: pool)

        score = 0
        index = 0
        selected = nil

        guard usable.count >= Self.minimumPoolSize else {
            questions = []
            state = .needsMoreWords(have: usable.count, need: Self.minimumPoolSize)
            return
        }

        let headwords = usable.map(\.word)
        questions = usable
            .shuffled(using: &rng)
            .prefix(Self.questionsPerRound)
            .enumerated()
            .map { offset, word in
                QuizQuestion(
                    id: offset,
                    answer: word.word,
                    partOfSpeech: word.partOfSpeech,
                    definition: word.definition,
                    options: Self.options(for: word.word, from: headwords, using: &rng)
                )
            }
        updateState()
    }

    private func updateState() {
        guard !questions.isEmpty else {
            state = .needsMoreWords(have: 0, need: Self.minimumPoolSize)
            return
        }
        if index < questions.count {
            state = .question(questions[index], index: index,
                              total: questions.count, selected: selected)
        } else {
            state = .finished(score: score, total: questions.count)
        }
    }

    /// The answer plus three distractors, in random order. Distractors come from
    /// the reader's own pool first — guessing between familiar words is the point
    /// — and only fall back to the dictionary at large when the pool runs dry.
    private static func options<G: RandomNumberGenerator>(
        for answer: String, from headwords: [String], using rng: inout G
    ) -> [String] {
        var options = [answer]
        var used: Set<String> = [answer.lowercased()]

        for word in headwords.shuffled(using: &rng) where options.count < optionCount {
            if used.insert(word.lowercased()).inserted { options.append(word) }
        }

        // Bounded, because randomWord() draws with replacement and can keep
        // handing back words already on the list.
        var attempts = 0
        while options.count < optionCount, attempts < 40 {
            attempts += 1
            guard let random = DictionaryStore.shared.randomWord() else { break }
            if used.insert(random.lowercased()).inserted { options.append(random) }
        }

        return options.shuffled(using: &rng)
    }

    /// Pool words resolved to a headword and its first definition, dropping the
    /// ones that would show a blank prompt. Inflected forms resolve to their base
    /// ("went" -> "go"), which is also how duplicates get collapsed.
    private static func usableWords(in pool: [String]) -> [QuizWord] {
        var seen = Set<String>()
        var words: [QuizWord] = []
        for term in pool {
            guard let entry = entry(for: term), let sense = firstSense(of: entry) else { continue }
            let definition = sense.definition.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !definition.isEmpty else { continue }
            guard seen.insert(entry.word.lowercased()).inserted else { continue }
            words.append(QuizWord(word: entry.word,
                                  partOfSpeech: sense.partOfSpeech,
                                  definition: definition))
        }
        return words
    }

    /// The sense the entry screen leads with — `senses` comes out of SQL ordered
    /// by part of speech alphabetically, which would quiz "go" on its adjective
    /// sense rather than the one the reader actually read.
    private static func firstSense(of entry: WordEntry) -> WordSense? {
        entry.sensesByPartOfSpeech.first?.senses.first ?? entry.senses.first
    }

    private static func entry(for term: String) -> WordEntry? {
        switch DictionaryStore.shared.lookup(term) {
        case .found(let entry): return entry
        case .redirected(_, let entries): return entries.first
        case .notFound: return nil
        }
    }

    private struct QuizWord {
        let word: String
        let partOfSpeech: String
        let definition: String
    }
}

/// SplitMix64. Foundation's default generator can't be seeded, and a round that
/// reshuffles itself mid-question would be unusable.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
