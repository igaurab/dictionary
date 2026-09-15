import AVFoundation
import Combine
import SwiftUI

/// Says an English headword aloud with the system's on-device voices.
///
/// Nothing is sent anywhere: iOS voices run locally. Every iPhone has a compact
/// English voice; the much better Enhanced and Premium ones are a free download
/// in the Settings app, the same "download it once, use it offline" deal as the
/// extra dictionaries. Apps can't trigger that download themselves, so Settings
/// explains where to get one and this picks the best voice that's installed.
@MainActor
final class Pronouncer: NSObject, ObservableObject {
    static let shared = Pronouncer()

    /// The word being spoken, so its button can show that it's playing.
    @Published private(set) var speakingWord: String?

    private let synthesizer = AVSpeechSynthesizer()

    /// A voice identifier, or empty for "the best one installed".
    static let voiceDefaultsKey = "pronunciationVoice"

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ word: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        // Playback, so the word is heard with the ring switch on silent: the
        // reader tapped a speaker button and expects sound. Other audio ducks
        // rather than stops.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio,
                                                         options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        let utterance = AVSpeechUtterance(string: word)
        utterance.voice = Self.preferredVoice()
        // A touch slower than conversation, the way a dictionary reads a word.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        speakingWord = word
        synthesizer.speak(utterance)
    }

    // MARK: - Voices

    /// Installed English voices, best first, then by region and name.
    static var englishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            // Novelty voices ("Bubbles", "Bad News") are no use for a dictionary.
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted {
                ($0.quality.rawValue, regionRank($1), $1.name) > ($1.quality.rawValue, regionRank($0), $0.name)
            }
    }

    static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let chosen = UserDefaults.standard.string(forKey: voiceDefaultsKey) ?? ""
        if !chosen.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: chosen) {
            return voice
        }
        return englishVoices.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// WordNet and the CMU pronunciations are American English, so American
    /// voices win ties.
    private static func regionRank(_ voice: AVSpeechSynthesisVoice) -> Int {
        switch voice.language {
        case "en-US": return 0
        case "en-GB": return 1
        default: return 2
        }
    }

    static func qualityName(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Compact"
        }
    }
}

extension Pronouncer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    private func finished() {
        guard !synthesizer.isSpeaking else { return }
        speakingWord = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// The speaker button beside a headword's pronunciation.
struct PronounceButton: View {
    @ObservedObject private var pronouncer = Pronouncer.shared
    let word: String
    var size: CGFloat = 17

    var body: some View {
        let speaking = pronouncer.speakingWord == word
        Button {
            pronouncer.speak(word)
        } label: {
            Image(systemName: speaking ? "speaker.wave.3.fill" : "speaker.wave.2")
                .font(.system(size: size))
                .symbolEffect(.variableColor.iterative, isActive: speaking)
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Pronounce \(word)")
        .accessibilityIdentifier("entry.pronounce")
    }
}
