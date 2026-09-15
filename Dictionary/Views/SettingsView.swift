import AVFoundation
import SwiftUI

/// Text size and about screen — the equivalent of Dictionary > Settings
/// and the ⌘+/⌘− text zoom on macOS.
struct SettingsView: View {
    @EnvironmentObject private var model: DictionaryViewModel
    @Environment(\.dismiss) private var dismiss
    /// Mirrors SpotlightIndexer's own default so the toggle reads correctly
    /// before the indexer has ever run.
    @AppStorage("spotlightIndexingEnabled") private var spotlightEnabled = true
    @EnvironmentObject private var library: DictionaryLibrary
    @State private var showingDictionaries = false
    @AppStorage(Pronouncer.voiceDefaultsKey) private var voiceID = ""
    @State private var voices: [AVSpeechSynthesisVoice] = []

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

                Section("Dictionaries") {
                    Button {
                        showingDictionaries = true
                    } label: {
                        LabeledContent("Dictionaries") {
                            Text(library.installed.isEmpty
                                 ? "WordNet 3.1"
                                 : "\(library.installed.count + 1) installed")
                        }
                    }
                    .tint(.primary)
                }

                Section("Pronunciation") {
                    Picker("Voice", selection: $voiceID) {
                        Text("Best Available").tag("")
                        ForEach(voices, id: \.identifier) { voice in
                            Text("\(voice.name) (\(voice.language), \(Pronouncer.qualityName(voice)))")
                                .tag(voice.identifier)
                        }
                    }
                    Button("Play Sample") {
                        Pronouncer.shared.speak("dictionary")
                    }
                    Text("Words are read by a voice stored on this iPhone, so pronunciation works offline. For a more natural voice, open the Settings app, search for \u{201C}Voices\u{201D}, pick English, and download an Enhanced or Premium voice. It appears here once downloaded.")
                        .font(.roboto(13))
                        .foregroundStyle(.secondary)
                }

                Section("Spotlight") {
                    Toggle("Look Up from Home Screen", isOn: $spotlightEnabled)
                    Text("Adds every word to iPhone search, so swiping down on the home screen and typing a word shows its definition. Indexing 147,478 words takes a minute the first time.")
                        .font(.roboto(13))
                        .foregroundStyle(.secondary)
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
            .sheet(isPresented: $showingDictionaries) {
                DictionariesSettingsView()
            }
            .onAppear {
                // Re-read on every visit: the reader may have just downloaded a
                // voice in the Settings app.
                voices = Pronouncer.englishVoices
            }
            .onChange(of: spotlightEnabled) { _, isOn in
                // AppStorage has already written the flag; this kicks off the
                // index build or teardown to match.
                Task.detached(priority: .utility) {
                    if isOn {
                        await SpotlightIndexer.indexIfNeeded(force: true)
                    } else {
                        await SpotlightIndexer.deleteIndex()
                    }
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
