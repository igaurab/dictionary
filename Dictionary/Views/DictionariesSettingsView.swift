import SwiftUI
import UniformTypeIdentifiers

/// Manage the dictionaries the app searches: the bundled WordNet, plus any
/// StarDict dictionaries the reader has imported.
///
/// StarDict is the format with the widest free selection, which is what makes
/// other languages possible at all — there is no Nepali or French WordNet in
/// the app bundle, but there are StarDict files for both.
struct DictionariesSettingsView: View {
    @EnvironmentObject private var library: DictionaryLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var isChoosingFile = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Built In") {
                    LabeledContent("WordNet 3.1", value: "147,478 words")
                        .font(.roboto(15))
                }

                Section {
                    ForEach(DictionaryCatalog.entries) { item in
                        downloadRow(for: item)
                    }
                } header: {
                    Text("Download")
                } footer: {
                    Text("Downloaded dictionaries are stored on this device and work offline. They are not part of the app, so they can be removed at any time.")
                        .font(.roboto(13))
                }

                Section("Imported") {
                    if library.installed.isEmpty {
                        Text("No dictionaries imported yet.")
                            .font(.roboto(15))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(library.installed) { dictionary in
                            row(for: dictionary)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                library.remove(library.installed[index])
                            }
                        }
                    }
                }

                Section {
                    if let progress = library.importProgress {
                        // Importing a large dictionary takes a few seconds and
                        // rewrites it into the app's own SQLite, so show real
                        // progress rather than an indefinite spinner.
                        ProgressView(value: progress) {
                            Text("Importing\u{2026}")
                                .font(.roboto(15))
                        }
                    } else {
                        Button("Add Dictionary\u{2026}") { isChoosingFile = true }
                    }
                } footer: {
                    Text("Choose a StarDict dictionary: a .tar.xz, .tar.gz or .zip archive, or a folder containing the .ifo, .idx and .dict files. Imported dictionaries work offline like the built-in one.")
                        .font(.roboto(13))
                }
            }
            .navigationTitle("Dictionaries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isChoosingFile,
                // A StarDict dictionary arrives either as a downloaded archive
                // or as the unpacked folder, and some people pick the .ifo.
                allowedContentTypes: [.folder, .zip, .item]
            ) { result in
                guard case .success(let url) = result else { return }
                Task {
                    do {
                        try await library.addDictionary(from: url)
                    } catch {
                        importError = error.localizedDescription
                    }
                }
            }
            .alert("Could Not Add Dictionary", isPresented: .constant(importError != nil)) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    // MARK: - Download catalogue

    @ViewBuilder
    private func downloadRow(for item: CatalogDictionary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.roboto(15))
                    Text(catalogSubtitle(for: item))
                        .font(.roboto(13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)

                if library.isInstalled(item) {
                    Text("Installed")
                        .font(.roboto(13))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("installed.\(item.id)")
                } else if library.isDownloading(item) {
                    // Cancelling mid-download is not supported, so the button is
                    // replaced rather than disabled in place.
                    EmptyView()
                } else {
                    Button("Download") { start(item) }
                        .font(.roboto(15))
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("download.\(item.id)")
                }
            }

            Text(item.summary)
                .font(.roboto(13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let progress = library.downloadProgress[item.id] {
                ProgressView(value: progress) {
                    Text(progress < 0.9 ? "Downloading\u{2026}" : "Installing\u{2026}")
                        .font(.roboto(13))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func start(_ item: CatalogDictionary) {
        Task {
            do {
                try await library.download(item)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func catalogSubtitle(for item: CatalogDictionary) -> String {
        let words = item.entryCount.formatted(.number.grouping(.automatic))
        let size = ByteCountFormatter.string(fromByteCount: item.downloadBytes,
                                             countStyle: .file)
        let separator = " \u{00B7} "
        return [item.language, "\(words) words", size, item.licence]
            .joined(separator: separator)
    }

    private func row(for dictionary: InstalledDictionary) -> some View {
        Toggle(isOn: Binding(
            get: { library.isEnabled(dictionary) },
            set: { library.setEnabled($0, for: dictionary) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dictionary.name)
                    .font(.roboto(15))
                Text(subtitle(for: dictionary))
                    .font(.roboto(13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func subtitle(for dictionary: InstalledDictionary) -> String {
        let words = dictionary.wordCount
            .formatted(.number.grouping(.automatic))
        guard let language = dictionary.language, !language.isEmpty else {
            return "\(words) words"
        }
        return "\(language) \u{00B7} \(words) words"
    }
}
