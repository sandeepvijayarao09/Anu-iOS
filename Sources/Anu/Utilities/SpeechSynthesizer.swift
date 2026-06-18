import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Speaks assistant replies aloud (voice OUT), completing the hands-free loop
/// that `SpeechRecognizer` starts (voice IN) — the conversational feel of the
/// new Siri. Thin wrapper over `AVSpeechSynthesizer`, gated by the
/// `speak_responses` Settings toggle.
@MainActor
final class SpeechSynthesizer: ObservableObject {
    /// UserDefaults key shared with the Settings toggle.
    static let enabledKey = "speak_responses"

    #if canImport(AVFoundation)
    private let synthesizer = AVSpeechSynthesizer()
    #endif

    @Published private(set) var isSpeaking = false

    /// Speaks `text` only if the user turned on spoken replies. No-op when the
    /// toggle is off, the text is blank, or synthesis is unavailable.
    func speakIfEnabled(_ text: String) {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        speak(text)
    }

    func speak(_ text: String) {
        guard let utterance = Self.utterance(for: text) else { return }
        #if canImport(AVFoundation)
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        configureAudioSession()
        synthesizer.speak(utterance)
        isSpeaking = true
        #endif
    }

    func stop() {
        #if canImport(AVFoundation)
        synthesizer.stopSpeaking(at: .immediate)
        #endif
        isSpeaking = false
    }

    #if canImport(AVFoundation)
    /// Builds a configured utterance, or nil for blank text. Pure + testable
    /// (no audio device needed).
    static func utterance(for text: String) -> AVSpeechUtterance? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        utterance.voice = AVSpeechSynthesisVoice(language: lang)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        return utterance
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // Duck other audio while speaking; don't fight the mic's record category.
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: [])
    }
    #endif
}
