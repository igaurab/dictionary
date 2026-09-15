import SwiftUI

/// The flashcard sheet: a word on the front, its definition on the back.
///
/// Set like an entry rather than like a game — the card is a plain bordered
/// panel, and the only motion is the flip itself.
struct FlashcardsView: View {
    @StateObject private var deck: FlashcardDeck
    @EnvironmentObject private var library: DictionaryLibrary
    @Environment(\.dismiss) private var dismiss

    /// `words` is the reader's own vocabulary for `.recents`, and ignored for
    /// `.random`, which draws its own.
    init(source: FlashcardSource, words: [String] = []) {
        _deck = StateObject(wrappedValue: FlashcardDeck(source: source, words: words))
    }

    var body: some View {
        NavigationStack {
            Group {
                if deck.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if deck.isEmpty {
                    emptyState
                } else if let card = deck.current {
                    cardScreen(card)
                } else {
                    finishedScreen
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if deck.source == .random && library.lexicons.count > 1 {
                    dictionaryChips
                }
            }
            .navigationTitle(deck.source.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Dictionaries

    /// Which dictionaries a random deck draws from, as toggles in the style of
    /// the source bar. Tapping one deals a fresh deck.
    private var dictionaryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(library.lexicons) { lexicon in
                    let selected = deck.lexicons.contains(lexicon)
                    Button {
                        deck.toggle(lexicon)
                    } label: {
                        Label(lexicon.label, systemImage: selected ? "checkmark" : "plus")
                            .labelStyle(ChipLabelStyle())
                            .font(.roboto(15, weight: selected ? .medium : .regular))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(selected
                                               ? Color(.secondarySystemBackground)
                                               : Color.clear)
                            )
                            .overlay(
                                Capsule().strokeBorder(Color.secondary.opacity(selected ? 0 : 0.35))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("flashcards.dictionary.\(lexicon.label)")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Screens

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(deck.source == .recents
                 ? "Look up a few words first."
                 : "No words are available right now.")
                .font(.roboto(15))
            if deck.source == .recents {
                Text("Your recent searches become flashcards.")
                    .font(.roboto(13))
            }
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cardScreen(_ card: Flashcard) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(deck.position)
                Spacer()
                Button("Shuffle") { deck.shuffle() }
            }
            .font(.roboto(13))
            .foregroundStyle(.secondary)

            cardFace(card)
                .padding(.top, 20)

            Text(deck.isRevealed ? "Tap to see the word" : "Tap to see the definition")
                .font(.roboto(13))
                .foregroundStyle(.secondary)
                .padding(.top, 14)

            Spacer(minLength: 16)

            HStack(spacing: 12) {
                Button {
                    deck.previous()
                } label: {
                    Text("Back")
                        .font(.roboto(17))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(deck.index == 0)

                Button {
                    deck.next()
                } label: {
                    Text(deck.isLastCard ? "Finish" : "Next")
                        .font(.roboto(17, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var finishedScreen: some View {
        VStack(spacing: 4) {
            Text("\(deck.cards.count)")
                .font(.roboto(40))
            Text(deck.cards.count == 1 ? "card reviewed" : "cards reviewed")
                .font(.roboto(15))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Button(deck.source == .random ? "New Words" : "Start Over") { deck.restart() }
                    .font(.roboto(17, weight: .medium))
                Button("Shuffle") { deck.shuffle() }
                    .font(.roboto(17))
                Button("Done") { dismiss() }
                    .font(.roboto(17))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - The card

    /// Two faces in a ZStack: the whole card turns, and the back is pre-turned
    /// so its text reads the right way round once it faces the reader.
    private func cardFace(_ card: Flashcard) -> some View {
        ZStack {
            front(card)
                .opacity(deck.isRevealed ? 0 : 1)
            back(card)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .opacity(deck.isRevealed ? 1 : 0)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
        )
        .rotation3DEffect(.degrees(deck.isRevealed ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        .animation(.easeInOut(duration: 0.35), value: deck.isRevealed)
        .contentShape(Rectangle())
        .onTapGesture { deck.flip() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(deck.isRevealed ? card.definition : card.word)
        .accessibilityHint("Double tap to flip the card")
    }

    private func front(_ card: Flashcard) -> some View {
        Text(card.word)
            .font(.roboto(32))
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.5)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if deck.showsDictionary {
                    Text(card.dictionary.uppercased())
                        .font(.roboto(12, weight: .medium))
                        .kerning(0.6)
                        .foregroundStyle(.secondary)
                        .padding(.top, 14)
                }
            }
    }

    private func back(_ card: Flashcard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !card.partOfSpeech.isEmpty {
                Text(card.partOfSpeech)
                    .font(.roboto(14, italic: true))
                    .foregroundStyle(.secondary)
            }
            Text(card.definition)
                .font(.roboto(20))
                .fixedSize(horizontal: false, vertical: true)
            if let example = card.example, !example.isEmpty {
                Text("\u{201C}\(example)\u{201D}")
                    .font(.roboto(15, italic: true))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }
}

#Preview("Recents") {
    FlashcardsView(source: .recents,
                   words: ["ephemeral", "laconic", "sanguine", "obdurate", "quixotic"])
}

#Preview("Random") {
    FlashcardsView(source: .random)
        .environmentObject(DictionaryLibrary.shared)
}

/// Icon then title, tight, for the dictionary chips.
private struct ChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .font(.system(size: 11, weight: .semibold))
            configuration.title
        }
    }
}
