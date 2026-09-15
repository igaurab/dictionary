import SwiftUI

/// The source switcher from the top of the macOS Dictionary window.
///
/// macOS lists every installed dictionary here — All, Dictionary, Thesaurus,
/// then each extra one by name — so this does too, driven by whatever the word
/// on screen actually has. A segmented control can't hold five or six labels on
/// a phone, so once the list outgrows the width it becomes a scrolling row of
/// chips rather than squeezing the text.
struct SourceBar: View {
    @EnvironmentObject private var model: DictionaryViewModel

    /// macOS shows a "95 found" count beside the title while a search is
    /// running; passing nil omits the line.
    var resultCount: Int?

    /// Above this many tabs the segmented control becomes unreadable.
    private let segmentedLimit = 3

    var body: some View {
        let sources = model.availableSources

        VStack(spacing: 6) {
            if let resultCount {
                Text(resultCount == 1 ? "1 found" : "\(resultCount) found")
                    .font(.roboto(13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            if sources.count > 1 {
                if sources.count <= segmentedLimit {
                    Picker("Source", selection: $model.source) {
                        ForEach(sources) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                } else {
                    chips(sources)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func chips(_ sources: [DictionarySource]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sources) { source in
                    let selected = source == model.source
                    Button {
                        model.source = source
                    } label: {
                        Text(source.label)
                            .font(.roboto(15, weight: selected ? .medium : .regular))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(selected
                                               ? Color(.secondarySystemBackground)
                                               : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            // The row scrolls, so it needs its own edge inset to sit flush with
            // the surrounding padding without clipping the first chip.
            .padding(.horizontal, 2)
        }
    }
}
