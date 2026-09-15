import WidgetKit
import SwiftUI

struct WordOfTheDayEntry: TimelineEntry {
    let date: Date
    let word: WidgetWord?
}

struct WordOfTheDayProvider: TimelineProvider {
    /// A real word, so the widget gallery and the placeholder never show
    /// scaffolding the user then watches get replaced.
    private static let sample = WidgetWord(
        word: "serendipity",
        pronunciation: "sˌɛrəndˈɪpɪti",
        partOfSpeech: "noun",
        definition: "good luck in making unexpected and fortunate discoveries"
    )

    func placeholder(in context: Context) -> WordOfTheDayEntry {
        WordOfTheDayEntry(date: Date(), word: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (WordOfTheDayEntry) -> Void) {
        let word = context.isPreview
            ? Self.sample
            : WidgetDictionaryStore.shared.wordOfTheDay(for: Date())
        completion(WordOfTheDayEntry(date: Date(), word: word))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WordOfTheDayEntry>) -> Void) {
        let now = Date()
        let calendar = Calendar.current
        let entry = WordOfTheDayEntry(
            date: now,
            word: WidgetDictionaryStore.shared.wordOfTheDay(for: now, calendar: calendar)
        )
        // One entry, replaced at midnight. The word is a function of the date,
        // so an early reload by WidgetKit just recomputes the same word.
        let midnight = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0),
                                         matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(60 * 60 * 24)
        completion(Timeline(entries: [entry], policy: .after(midnight)))
    }
}

struct WordOfTheDayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WordOfTheDay", provider: WordOfTheDayProvider()) { entry in
            WordOfTheDayView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Word of the Day")
        .description("A new word from WordNet each morning, with its first definition.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct WordOfTheDayView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WordOfTheDayEntry

    private var isMedium: Bool { family == .systemMedium }

    var body: some View {
        Group {
            if let word = entry.word {
                content(word)
                    .widgetURL(WidgetDeepLink.word(word.word))
            } else {
                // Only reachable if the bundled database failed to open.
                Text("Dictionary")
                    .font(.roboto(15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .widgetURL(WidgetDeepLink.search)
            }
        }
    }

    private func content(_ word: WidgetWord) -> some View {
        VStack(alignment: .leading, spacing: isMedium ? 6 : 4) {
            Text("WORD OF THE DAY")
                .font(.roboto(isMedium ? 10 : 9, weight: .medium))
                .tracking(0.9)
                .foregroundStyle(Color.dictionaryAccent)

            Text(word.word)
                .font(.roboto(isMedium ? 30 : 22, weight: .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.55)

            if let pronunciation = word.pronunciation, !pronunciation.isEmpty {
                Text("|\u{2009}\(pronunciation)\u{2009}|")
                    .font(.roboto(isMedium ? 13 : 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Divider()
                .padding(.top, isMedium ? 2 : 1)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(word.partOfSpeech)
                    .font(.roboto(isMedium ? 13 : 11, weight: .bold, italic: true))
                    .foregroundStyle(.secondary)
                Text(word.definition)
                    .font(.roboto(isMedium ? 15 : 12))
                    .foregroundStyle(.primary)
            }
            .lineLimit(isMedium ? 4 : 4)
            .minimumScaleFactor(0.8)
            .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
