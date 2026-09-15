import SwiftUI
import UIKit

/// Leaf through a dictionary from A to Z, the way you read a printed one.
///
/// The list is a UITableView rather than a SwiftUI List: it has the Contacts-
/// style letter index down the side built in, collapses that index with dots
/// when forty-odd Devanagari letters don't fit, and asks for rows strictly on
/// demand, so half a million fixed-height rows cost no more than a hundred.
struct BrowseView: View {
    @EnvironmentObject private var model: DictionaryViewModel
    @EnvironmentObject private var library: DictionaryLibrary
    @ObservedObject private var indexes = BrowseIndexStore.shared
    @Environment(\.dismiss) private var dismiss

    @AppStorage("browseLexicon") private var selectedID = Lexicon.wordNet.id
    @State private var index: BrowseIndex?
    @State private var loadError: String?
    @State private var path: [String] = []

    /// Falls back to WordNet when the remembered dictionary was removed or
    /// switched off.
    private var lexicon: Lexicon {
        library.lexicons.first { $0.id == selectedID } ?? .wordNet
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(lexicon.label)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if library.lexicons.count > 1 {
                        ToolbarItem(placement: .topBarLeading) {
                            dictionaryMenu
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .navigationDestination(for: String.self) { _ in
                    EntryPage()
                }
        }
        .handlesLookupLinks(model)
        .task(id: lexicon) {
            await open(lexicon)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let index, index.wordCount > 0 {
            BrowseTable(index: index, textScale: model.textScale) { word in
                model.lookUp(word, from: lexicon)
                path = [word]
            }
            .ignoresSafeArea(edges: .bottom)
        } else if let loadError {
            message(loadError)
        } else if let fraction = indexes.progress[lexicon.id] {
            // Only the first visit to a dictionary builds its word list.
            VStack(spacing: 12) {
                ProgressView(value: fraction)
                Text("Putting \(lexicon.label) in order\u{2026}")
                    .font(.roboto(15))
                Text("This happens once per dictionary.")
                    .font(.roboto(13))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 48)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var dictionaryMenu: some View {
        Menu {
            Picker("Dictionary", selection: $selectedID) {
                ForEach(library.lexicons) { lexicon in
                    Text(lexicon.name).tag(lexicon.id)
                }
            }
        } label: {
            Label("Dictionary", systemImage: "books.vertical")
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.roboto(15))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func open(_ lexicon: Lexicon) async {
        index = nil
        loadError = nil
        do {
            let opened = try await indexes.index(for: lexicon)
            // The reader may have picked another dictionary while this built.
            guard lexicon.id == self.lexicon.id else { return }
            index = opened
        } catch {
            guard lexicon.id == self.lexicon.id else { return }
            loadError = error.localizedDescription
        }
    }
}

/// UIKit's accessibility for a table describes every row, which for 147,000
/// words means building that many cells on the main thread the moment
/// VoiceOver or UI testing looks at the screen — the app froze for over a
/// minute. Exposing only the rows on screen (plus the letter index) keeps it
/// instant; scrolling still reveals the rest, as it does for sighted readers.
private final class WordTableView: UITableView {
    private var onScreenElements: [Any] {
        let index = subviews.filter { String(describing: type(of: $0)).contains("Index") }
        let headers = (0..<numberOfSections).compactMap { section -> UIView? in
            guard let header = headerView(forSection: section), header.window != nil else { return nil }
            return header
        }
        return headers + visibleCells + index
    }

    override var accessibilityElements: [Any]? {
        get { onScreenElements }
        set {}
    }

    override func accessibilityElementCount() -> Int {
        onScreenElements.count
    }

    override func accessibilityElement(at index: Int) -> Any? {
        let elements = onScreenElements
        return elements.indices.contains(index) ? elements[index] : nil
    }

    override func index(ofAccessibilityElement element: Any) -> Int {
        onScreenElements.firstIndex { ($0 as AnyObject) === (element as AnyObject) } ?? NSNotFound
    }
}

/// The word list itself: one sticky header per letter, the letter index down
/// the trailing edge, one row per headword.
private struct BrowseTable: UIViewRepresentable {
    let index: BrowseIndex
    let textScale: Double
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(index: index, onSelect: onSelect)
    }

    func makeUIView(context: Context) -> UITableView {
        let table = WordTableView(frame: .zero, style: .plain)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.register(UITableViewCell.self, forCellReuseIdentifier: Coordinator.cellID)
        table.sectionHeaderTopPadding = 0
        table.sectionIndexColor = .secondaryLabel
        table.sectionIndexBackgroundColor = .clear
        // Fixed heights: with estimated ones the table measures rows as they
        // scroll past, and a flick through the letter index lands off target.
        table.estimatedRowHeight = 0
        table.estimatedSectionHeaderHeight = 0
        context.coordinator.apply(textScale: textScale, to: table)
        table.accessibilityIdentifier = "browse.table"
        return table
    }

    func updateUIView(_ table: UITableView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        if coordinator.index !== index {
            coordinator.index = index
            table.reloadData()
            if table.numberOfSections > 0, table.numberOfRows(inSection: 0) > 0 {
                table.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
            }
        }
        if coordinator.textScale != textScale {
            coordinator.apply(textScale: textScale, to: table)
            table.reloadData()
        }
    }

    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        static let cellID = "word"

        var index: BrowseIndex
        var onSelect: (String) -> Void
        private(set) var textScale: Double = 0
        private var font = UIFont.systemFont(ofSize: 17)
        private var headerFont = UIFont.systemFont(ofSize: 15)

        init(index: BrowseIndex, onSelect: @escaping (String) -> Void) {
            self.index = index
            self.onSelect = onSelect
        }

        func apply(textScale: Double, to table: UITableView) {
            self.textScale = textScale
            let scale = CGFloat(textScale)
            font = UIFont(name: "Roboto-Regular", size: 17 * scale) ?? .systemFont(ofSize: 17 * scale)
            headerFont = UIFont(name: "Roboto-Medium", size: 15 * scale) ?? .boldSystemFont(ofSize: 15 * scale)
            table.rowHeight = (44 * scale).rounded()
            table.sectionHeaderHeight = (30 * scale).rounded()
        }

        func numberOfSections(in tableView: UITableView) -> Int {
            index.sections.count
        }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            index.sections[section].count
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
            var content = UIListContentConfiguration.cell()
            content.text = word(at: indexPath)
            content.textProperties.font = font
            content.textProperties.numberOfLines = 1
            cell.contentConfiguration = content
            return cell
        }

        func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
            let header = UITableViewHeaderFooterView()
            var content = UIListContentConfiguration.plainHeader()
            content.text = index.sections[section].title
            content.textProperties.font = headerFont
            content.textProperties.color = .secondaryLabel
            header.contentConfiguration = content
            return header
        }

        func sectionIndexTitles(for tableView: UITableView) -> [String]? {
            index.indexTitles.count > 1 ? index.indexTitles.map(\.title) : nil
        }

        func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String,
                       at position: Int) -> Int {
            index.indexTitles[position].section
        }

        func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: true)
            onSelect(word(at: indexPath))
        }

        private func word(at indexPath: IndexPath) -> String {
            index.word(at: index.sections[indexPath.section].start + indexPath.row)
        }
    }
}
