import SwiftUI

/// Text size and about screen — the equivalent of Dictionary > Settings
/// and the ⌘+/⌘− text zoom on macOS.
struct SettingsView: View {
    @EnvironmentObject private var model: DictionaryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Text Size") {
                    HStack(spacing: 16) {
                        Text("A")
                            .font(.roboto(14))
                        Slider(value: $model.textScale, in: 0.8...1.6, step: 0.1)
                        Text("A")
                            .font(.roboto(26))
                    }
                    Text("example")
                        .font(.roboto(17 * model.textScale))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .foregroundStyle(.secondary)
                    Button("Reset to Default") {
                        model.textScale = 1.0
                    }
                    .disabled(model.textScale == 1.0)
                }

                Section("Home Screen") {
                    Toggle("Show Recent Searches", isOn: $model.showRecentsOnHome)
                    Text("When off, the app opens on an empty page. Recent searches are always available from the ••• menu.")
                        .font(.roboto(13))
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent("Definitions", value: "WordNet 3.1")
                    LabeledContent("Pronunciations", value: "CMU Pronouncing Dictionary")
                    LabeledContent("Words", value: "147,478")
                    LabeledContent("Senses", value: "207,235")
                }

                Section {
                    Text("This dictionary works entirely offline. Definitions, examples, synonyms, and antonyms come from WordNet 3.1, © 2011 Princeton University, used under the WordNet license. Pronunciations are derived from the CMU Pronouncing Dictionary, © Carnegie Mellon University, used under its BSD-style license. Set in Roboto, © 2011 The Roboto Project Authors, used under the SIL Open Font License 1.1.")
                        .font(.roboto(13))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(DictionaryViewModel())
}
