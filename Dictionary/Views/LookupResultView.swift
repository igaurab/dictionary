import SwiftUI

/// Renders the outcome of a lookup: the entry, a redirect through an
/// inflected form, or a "no entry found" page with spelling suggestions.
struct LookupResultView: View {
    @EnvironmentObject private var model: DictionaryViewModel
    let term: String
    let result: LookupResult

    var body: some View {
        switch result {
        case .found(let entry):
            EntryScrollView(entries: [entry], redirectedFrom: nil)

        case .redirected(let from, let entries):
            EntryScrollView(entries: entries, redirectedFrom: from)

        case .notFound(let suggestions):
            if model.importedEntries.isEmpty {
                noEntryView(suggestions: suggestions)
            } else {
                // WordNet doesn't have it, but an imported dictionary does -
                // the usual case for a word in another language.
                EntryScrollView(entries: [], redirectedFrom: nil)
            }
        }
    }

    private func noEntryView(suggestions: [String]) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No entries found for “\(term)”.")
                        .font(.roboto(17, weight: .medium))
                    if !suggestions.isEmpty {
                        Text("Did you mean:")
                            .font(.roboto(15))
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowSeparator(.hidden)
            }
            Section {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        model.lookUp(suggestion)
                    } label: {
                        Text(suggestion)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(term)
    }
}

/// The scrolling entry page with the macOS-style source bar
/// (All / Dictionary / Thesaurus) pinned above the content.
struct EntryScrollView: View {
    @EnvironmentObject private var model: DictionaryViewModel
    let entries: [WordEntry]
    let redirectedFrom: String?

    var body: some View {
        VStack(spacing: 0) {
            SourceBar()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let from = redirectedFrom {
                        redirectNote(from: from)
                    }
                    if model.source.showsWordNet {
                        ForEach(entries) { entry in
                            EntryView(entry: entry, source: model.source)
                            if entry.id != entries.last?.id {
                                Divider()
                            }
                        }
                    }
                    ForEach(shownImported) { imported in
                        if showsWordNetContent || imported != shownImported.first {
                            Divider()
                        }
                        importedSection(imported)
                    }
                    attributionFooter
                }
                .frame(maxWidth: 700, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle(entries.first?.word ?? model.currentTerm ?? "")
    }

    /// The imported dictionaries the selected source lets through.
    private var shownImported: [ImportedDefinition] {
        model.importedEntries.filter { model.source.shows(importedName: $0.dictionaryName) }
    }

    /// Whether anything from WordNet is actually on screen above the imported
    /// sections, which decides who draws the headword and the divider.
    private var showsWordNetContent: Bool {
        model.source.showsWordNet && !entries.isEmpty
    }

    /// An imported dictionary's text for the word. StarDict entries are free
    /// text rather than structured senses, so they are shown as a block under
    /// the dictionary's own name.
    @ViewBuilder
    private func importedSection(_ imported: ImportedDefinition) -> some View {
        let scale = CGFloat(model.textScale)
        VStack(alignment: .leading, spacing: 10) {
            if !showsWordNetContent && imported == shownImported.first {
                Text(model.currentTerm ?? "")
                    .font(.roboto(34 * scale))
            }
            Text(imported.dictionaryName.uppercased())
                .font(.roboto(13 * scale, weight: .medium))
                .foregroundStyle(.secondary)
            Divider()
            Text(.lookupText(imported.definition))
                .font(.roboto(17 * scale))
                .textSelection(.enabled)
        }
    }

    private func redirectNote(from: String) -> some View {
        (Text("“\(from)” is a form of ")
            + Text(entries.map(\.word).joined(separator: ", ")).italic())
            .font(.roboto(15))
            .foregroundStyle(.secondary)
    }

    /// Only credit WordNet when WordNet actually supplied something: an entry
    /// that came entirely from an imported dictionary is not theirs.
    @ViewBuilder
    private var attributionFooter: some View {
        if showsWordNetContent {
            Text("WordNet 3.1 © Princeton University · Pronunciations from the CMU Pronouncing Dictionary")
                .font(.roboto(11))
                .foregroundStyle(.tertiary)
                .padding(.top, 12)
        }
    }
}

/// One dictionary entry, laid out like the New Oxford entries in the
/// macOS Dictionary app: serif headword, IPA between vertical bars,
/// italic part-of-speech labels, numbered senses with italic examples.
struct EntryView: View {
    @EnvironmentObject private var model: DictionaryViewModel
    let entry: WordEntry
    let source: DictionarySource

    private var scale: CGFloat { CGFloat(model.textScale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header

            if source == .all || source == .dictionary {
                dictionarySection
            }

            if source == .all || source == .thesaurus {
                if entry.hasThesaurusContent {
                    thesaurusSection
                } else if source == .thesaurus {
                    Text("No thesaurus entries for “\(entry.word)”.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.word)
                .font(.roboto(34 * scale))
                .textSelection(.enabled)
            HStack(alignment: .center, spacing: 6) {
                if let pronunciation = entry.pronunciation {
                    Text("| \(pronunciation) |")
                        .font(.roboto(17 * scale))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                // WordNet is English, so every entry here can be read aloud.
                PronounceButton(word: entry.word, size: 17 * scale)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    // MARK: Dictionary

    @ViewBuilder
    private var dictionarySection: some View {
        if source == .all {
            sourceHeader("Dictionary")
        }
        ForEach(entry.sensesByPartOfSpeech, id: \.partOfSpeech) { group in
            VStack(alignment: .leading, spacing: 12) {
                partOfSpeechLabel(group.partOfSpeech)
                ForEach(group.senses) { sense in
                    senseView(sense, numbered: group.senses.count > 1)
                }
            }
        }
    }

    private func senseView(_ sense: WordSense, numbered: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if numbered {
                Text("\(sense.senseNumber)")
                    .font(.roboto(15 * scale, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 16 * scale, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(AttributedString.lookupText(sense.definition))
                    .font(.roboto(17 * scale))
                    .tint(.primary)

                ForEach(Array(sense.examples.enumerated()), id: \.offset) { _, example in
                    (Text(": ").foregroundColor(.secondary)
                        + Text(AttributedString.lookupText(example, color: .secondary)))
                        .font(.roboto(16 * scale, italic: true))
                        .tint(.secondary)
                }
            }
        }
    }

    // MARK: Thesaurus

    @ViewBuilder
    private var thesaurusSection: some View {
        if source == .all {
            sourceHeader("Thesaurus")
        }
        ForEach(entry.sensesByPartOfSpeech, id: \.partOfSpeech) { group in
            let senses = group.senses.filter { !$0.synonyms.isEmpty || !$0.antonyms.isEmpty }
            if !senses.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    partOfSpeechLabel(group.partOfSpeech)
                    ForEach(senses) { sense in
                        thesaurusSenseView(sense, numbered: senses.count > 1)
                    }
                }
            }
        }
    }

    private func thesaurusSenseView(_ sense: WordSense, numbered: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if numbered {
                Text("\(sense.senseNumber)")
                    .font(.roboto(15 * scale, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 16 * scale, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(sense.definition)
                    .font(.roboto(15 * scale))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !sense.synonyms.isEmpty {
                    Text(AttributedString.lookupWordList(sense.synonyms, color: .accentColor))
                        .font(.roboto(17 * scale))
                }
                if !sense.antonyms.isEmpty {
                    (Text("antonyms: ")
                        .font(.roboto(15 * scale, italic: true))
                        .foregroundColor(.secondary)
                        + Text(AttributedString.lookupWordList(sense.antonyms, color: .accentColor))
                        .font(.roboto(17 * scale)))
                }
            }
        }
    }

    // MARK: Shared

    private func sourceHeader(_ title: String) -> some View {
        Text(title)
            .font(.roboto(13 * scale, weight: .medium))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .kerning(0.8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Divider()
            }
    }

    private func partOfSpeechLabel(_ partOfSpeech: String) -> some View {
        Text(partOfSpeech)
            .font(.roboto(19 * scale, weight: .medium, italic: true))
            .foregroundStyle(Color.accentColor)
    }
}
