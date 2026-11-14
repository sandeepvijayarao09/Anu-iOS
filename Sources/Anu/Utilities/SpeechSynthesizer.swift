import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Speaks assistant replies aloud (voice OUT), completing the hands-free loop
/// that `SpeechRecognizer` starts (voice IN) — the conversational feel of the
/// new Siri. Thin wrapper over `AVSpeechSynthesizer`, gated by the
/// `speak_responses` Settings toggle. Sentences can be queued as an answer
/// streams, so Anu starts talking before the answer is finished (ADR-129).
@MainActor
final class SpeechSynthesizer: ObservableObject {
    /// UserDefaults key shared with the Settings toggle.
    static let enabledKey = "speak_responses"

    #if canImport(AVFoundation)
    private var synthesizer = AVSpeechSynthesizer()
    private lazy var observer = SpeechSynthesizerObserver(owner: self)
    #endif
    #if os(iOS)
    /// Live talk plays speech through the voice-processing engine, so the
    /// echo canceller can take Anu's own voice out of the microphone (barge-in).
    var duplex: DuplexVoiceEngine? = .shared
    /// The utterances now playing through `duplex`.
    private var onDuplex = false
    #endif

    @Published private(set) var isSpeaking = false
    /// Cadence of the current utterance, 0...1. Pulses on each spoken word and
    /// decays between them, so `VoiceOrb` moves with the speech rather than on
    /// a loop of its own. Zero whenever nothing is being spoken.
    @Published private(set) var level: Double = 0

    /// In voice mode the microphone stays open while Anu speaks (barge-in),
    /// so speech shares the voice-chat session (echo cancellation) instead of
    /// switching to a playback-only one.
    var conversational = false
    /// Called when the last queued utterance has finished on its own.
    var onFinished: (() -> Void)?

    private var decayTimer: Timer?
    private var queued = 0

    /// Speaks `text` only if the user turned on spoken replies. No-op when the
    /// toggle is off, the text is blank, or synthesis is unavailable.
    func speakIfEnabled(_ text: String) {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        speak(text)
    }

    /// Replaces anything being said with `text`.
    func speak(_ text: String) {
        #if canImport(AVFoundation)
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        queued = 0
        #endif
        #if os(iOS)
        // Replaced, not finished: no "done speaking" for the old answer.
        if onDuplex {
            onDuplex = false
            duplex?.stopSpeaking()
            finishSpeaking()
        }
        #endif
        enqueue(text)
    }

    /// Adds `text` after whatever is being said.
    func enqueue(_ text: String) {
        #if canImport(AVFoundation)
        guard let utterance = Self.utterance(for: text) else { return }
        if !isSpeaking { configureAudioSession() }
        #if os(iOS)
        if Self.routesThroughEngine(conversational: conversational, available: DuplexVoiceEngine.available,
                                    speakingDirectly: isSpeaking && !onDuplex),
           let duplex {
            wire(duplex)
            if duplex.speak(utterance) {
                onDuplex = true
                if !isSpeaking {
                    isSpeaking = true
                    startDecay()
                }
                return
            }
        }
        #endif
        synthesizer.delegate = observer
        synthesizer.speak(utterance)
        queued += 1
        if !isSpeaking {
            isSpeaking = true
            startDecay()
        }
        #endif
    }

    func stop() {
        #if canImport(AVFoundation)
        queued = 0
        synthesizer.stopSpeaking(at: .immediate)
        #endif
        #if os(iOS)
        if onDuplex {
            onDuplex = false
            duplex?.stopSpeaking()
        }
        #endif
        finishSpeaking()
    }

    /// Whether an utterance goes through the voice-processing engine: only in
    /// live talk, only when the microphone may be used, and never in the middle
    /// of speech already playing the ordinary way (it would play over it).
    nonisolated static func routesThroughEngine(conversational: Bool, available: Bool, speakingDirectly: Bool) -> Bool {
        conversational && available && !speakingDirectly
    }

    /// After a media-services reset: new synthesizer and engine.
    func rebuildAudio() {
        stop()
        #if canImport(AVFoundation)
        synthesizer = AVSpeechSynthesizer()
        #endif
        #if os(iOS)
        duplex?.rebuild()
        #endif
    }

    #if os(iOS)
    private func wire(_ duplex: DuplexVoiceEngine) {
        duplex.onLevel = { [weak self] level in
            guard let self, self.onDuplex else { return }
            self.level = max(self.level, 0.35 + level * 0.6)
        }
        duplex.onEvent = { [weak self] event in
            guard let self, self.onDuplex, event == .allFinished else { return }
            self.onDuplex = false
            guard self.isSpeaking else { return }
            self.finishSpeaking()
            self.onFinished?()
        }
    }
    #endif

    // MARK: - Delegate callbacks
    //
    // `isSpeaking` used to be set on `speak()` and cleared only by `stop()`, so
    // an utterance that ended on its own left it stuck at `true`. These hooks
    // close that loop and supply the per-word cadence the orb animates on.

    fileprivate func utteranceFinished() {
        queued = max(queued - 1, 0)
        guard queued == 0, isSpeaking else { return }
        finishSpeaking()
        onFinished?()
    }

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
        utterance.voice = preferredVoice()
        return utterance
    }

    /// The clearest installed voice for the user's language, the country's
    /// own first (VoicePick). Every system voice runs on the device.
    static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let country = Locale.current.region?.identifier ?? ""
        let candidates = AVSpeechSynthesisVoice.speechVoices().map { voice -> TTSVoiceCandidate in
            let parts = voice.language.split(separator: "-")
            return TTSVoiceCandidate(identifier: voice.identifier,
                                     language: parts.first.map(String.init) ?? voice.language,
                                     country: parts.count > 1 ? String(parts[1]) : "",
                                     quality: voice.quality.rawValue)
        }
        if let pick = VoicePick.best(candidates, language: lang, country: country),
           let voice = AVSpeechSynthesisVoice(identifier: pick.identifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: lang) ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private func configureAudioSession() {
        // AVAudioSession is iOS-only; macOS routes speech without one.
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if conversational {
            try? session.setCategory(.playAndRecord, mode: .voiceChat,
                                     options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
        } else {
            // Duck other audio while speaking; don't fight the mic's record category.
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        }
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
        Task { @MainActor [weak owner] in owner?.utteranceFinished() }
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
