import WidgetKit
import SwiftUI

struct SearchEntry: TimelineEntry {
    let date: Date
}

/// Nothing to schedule: the widget is a button, not a display.
struct SearchProvider: TimelineProvider {
    func placeholder(in context: Context) -> SearchEntry { SearchEntry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (SearchEntry) -> Void) {
        completion(SearchEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SearchEntry>) -> Void) {
        completion(Timeline(entries: [SearchEntry(date: Date())], policy: .never))
    }
}

struct SearchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DictionarySearch", provider: SearchProvider()) { _ in
            SearchWidgetView()
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Search")
        .description("Open Dictionary with the search field ready.")
        .supportedFamilies([.systemSmall])
    }
}

struct SearchWidgetView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Text("Search")
                .font(.roboto(22))
            Text("Dictionary")
                .font(.roboto(12, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(WidgetDeepLink.search)
    }
}
