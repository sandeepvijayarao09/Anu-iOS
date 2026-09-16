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
    private lazy var observer = SpeechSynthesizerObserver(owner: self)
    #endif

    @Published private(set) var isSpeaking = false
    /// Cadence of the current utterance, 0...1. Pulses on each spoken word and
    /// decays between them, so `VoiceOrb` moves with the speech rather than on
    /// a loop of its own. Zero whenever nothing is being spoken.
    @Published private(set) var level: Double = 0

    private var decayTimer: Timer?

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
        synthesizer.delegate = observer
        synthesizer.speak(utterance)
        isSpeaking = true
        startDecay()
        #endif
    }

    func stop() {
        #if canImport(AVFoundation)
        synthesizer.stopSpeaking(at: .immediate)
        #endif
        finishSpeaking()
    }

    // MARK: - Delegate callbacks
    //
    // `isSpeaking` used to be set on `speak()` and cleared only by `stop()`, so
    // an utterance that ended on its own left it stuck at `true`. These hooks
    // close that loop and supply the per-word cadence the orb animates on.

    fileprivate func finishSpeaking() {
        decayTimer?.invalidate()
        decayTimer = nil
        isSpeaking = false
        level = 0
    }

    /// Kick the level on each word. Longer words land harder, which gives the
    /// orb a rhythm that tracks the sentence instead of a flat throb.
    fileprivate func pulse(wordLength: Int) {
        let weighted = 0.5 + min(Double(wordLength), 10) / 10 * 0.45
        level = max(level, weighted)
    }

    /// Between words the level eases back toward a floor, so the orb stays
    /// alive through pauses without going still.
    private func startDecay() {
        decayTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isSpeaking else { return }
                self.level += (0.18 - self.level) * 0.18
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        decayTimer = timer
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
        // AVAudioSession is iOS-only; macOS routes speech without one.
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // Duck other audio while speaking; don't fight the mic's record category.
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: [])
        #endif
    }
    #endif
}

#if canImport(AVFoundation)
/// Bridges `AVSpeechSynthesizerDelegate` (ObjC, any thread) onto the main
/// actor. Kept as a separate object so `SpeechSynthesizer` doesn't have to
/// inherit from `NSObject` just to receive four callbacks.
final class SpeechSynthesizerObserver: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private weak var owner: SpeechSynthesizer?

    init(owner: SpeechSynthesizer) {
        self.owner = owner
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak owner] in owner?.finishSpeaking() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak owner] in owner?.finishSpeaking() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        let length = characterRange.length
        Task { @MainActor [weak owner] in owner?.pulse(wordLength: length) }
    }
}
#endif
