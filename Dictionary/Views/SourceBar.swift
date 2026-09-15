import SwiftUI

/// The All / Dictionary / Thesaurus switcher from the top of the macOS
/// Dictionary window. It sits above both the results list and the entry, so
/// the chosen source is visible while you are still picking a word rather than
/// only after you have opened one.
struct SourceBar: View {
    @EnvironmentObject private var model: DictionaryViewModel

    /// macOS shows a "95 found" count beside the title while a search is
    /// running; passing nil omits the line.
    var resultCount: Int?

    var body: some View {
        VStack(spacing: 6) {
            if let resultCount {
                Text(resultCount == 1 ? "1 found" : "\(resultCount) found")
                    .font(.roboto(13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            Picker("Source", selection: $model.source) {
                ForEach(DictionarySource.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}
