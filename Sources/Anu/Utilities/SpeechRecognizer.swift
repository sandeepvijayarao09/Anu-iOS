import Foundation

/// Milliseconds on a monotonic clock, for the endpointer.
enum VoiceClock {
    static func nowMs() -> Int { Int(ProcessInfo.processInfo.systemUptime * 1000) }
}

#if os(iOS)
import Speech
import AVFoundation

/// Voice-first input: on-device speech recognition streaming a live
/// transcript. Tap to start, tap to stop; the final transcript is handed
/// to `onFinalTranscript` (the chat auto-sends it). The `Endpointer` ends a
/// listen at a natural pause (700 ms after a finished-sounding sentence,
/// up to 1.8 s when it trails off), sooner than the recognizer's own timeout.
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var errorMessage: String?
    /// Smoothed microphone amplitude, 0...1. Drives `VoiceOrb`; it is real
    /// signal off the same tap that feeds recognition, not a decorative loop.
    @Published var level: Double = 0

    /// Called once per recording with the final transcript (non-empty).
    var onFinalTranscript: ((String) -> Void)?
    /// Called when a listen ends: whether it heard words, and whether it
    /// failed (no microphone, no permission). Drives live talk.
    var onListenEnded: ((_ heardWords: Bool, _ failed: Bool) -> Void)?

    /// In voice mode the session stays in voice-chat mode between listens, so
    /// speech and barge-in don't flip categories under each other.
    var keepsSessionActive = false
    /// Injectable timing (tests, tuning). Defaults are Android's ADR-129 values.
    var endpointQuickMs = Endpointer.quickMs
    var endpointSlowMs = Endpointer.slowMs
    var clock: () -> Int = VoiceClock.nowMs

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var endpointer = Endpointer()
    private var endpointTimer: Timer?
    private var failed = false

    func toggle() {
        if isRecording {
            stop()
        } else {
            Task { await start() }
        }
    }

    func start() async {
        guard !isRecording else { return }
        errorMessage = nil
        transcript = ""
        failed = false

        let speechAuth = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard speechAuth == .authorized else {
            fail("Voice input needs Speech Recognition access. Enable it in Settings › Anu, or just type instead.")
            return
        }
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else {
            fail("Voice input needs Microphone access. Enable it in Settings › Anu, or just type instead.")
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            fail("Speech recognition unavailable")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            // Voice chat: the system's echo cancellation, so Anu's own voice
            // isn't heard as the user (barge-in, ADR-129).
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true // privacy: never leaves the device
            }
            self.request = request

            let inputNode = audioEngine.inputNode
            try? inputNode.setVoiceProcessingEnabled(true)
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                // Runs on an audio thread — do the arithmetic here and hand the
                // main actor a single number, not the buffer.
                let amplitude = Self.normalizedAmplitude(of: buffer)
                Task { @MainActor [weak self] in self?.absorb(amplitude) }
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            endpointer = Endpointer(quickMs: endpointQuickMs, slowMs: endpointSlowMs,
                                    language: recognizer.locale.language.languageCode?.identifier ?? "en")
            startEndpointTimer()

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let failure = error
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    if let text {
                        self.transcript = text
                        self.endpointer.partial(text, now: self.clock())
                        if isFinal { self.stop() }
                    }
                    if let failure {
                        // Recognition ended. A silence timeout after real
                        // speech is routine — surface nothing and send what we
                        // have. Dying with an empty transcript means the mic
                        // never delivered audio, which the user needs told.
                        if self.transcript.trimmingCharacters(in: .whitespaces).isEmpty {
                            self.errorMessage = Self.describe(failure)
                            self.failed = true
                        }
                        self.stop()
                    }
                }
            }
        } catch {
            cleanupAudio()
            fail("Could not start recording: \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        onListenEnded?(false, true)
    }

    /// Turns a recognition failure into something worth reading. The
    /// Simulator has no usable audio input, so this is the message you get
    /// there — the feature needs real hardware.
    nonisolated static func describe(_ error: Error) -> String {
        #if targetEnvironment(simulator)
        return "The Simulator has no microphone input, so voice can't run here. Try it on a device."
        #else
        return "Didn't catch that — check microphone access in Settings and try again."
        #endif
    }

    /// Folds a new sample into `level` with an asymmetric filter: jump toward
    /// a louder reading, ease down from it. Matches how a level meter feels —
    /// snappy onset, graceful decay — and hides per-buffer jitter.
    private func absorb(_ amplitude: Double) {
        let smoothing = amplitude > level ? 0.45 : 0.12
        level += (amplitude - level) * smoothing
        if isRecording { endpointer.level(amplitude, now: clock()) }
    }

    /// Checks for the end of the turn ten times a second.
    private func startEndpointTimer() {
        endpointTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                if self.endpointer.done(now: self.clock()) { self.stop() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        endpointTimer = timer
    }

    /// Peak-normalized RMS of a buffer, mapped onto a decibel scale so quiet
    /// speech still visibly moves the orb.
    nonisolated static func normalizedAmplitude(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()
        guard rms > 0 else { return 0 }
        // -50 dBFS reads as silence, 0 dBFS as full deflection.
        let decibels = 20 * log10(Double(rms))
        return min(max((decibels + 50) / 50, 0), 1)
    }

    /// After a media-services reset every audio object is dead: stop, and
    /// listen with a new engine next time.
    func rebuildAudio() {
        stop()
        audioEngine = AVAudioEngine()
    }

    func stop() {
        guard isRecording else { return }
        level = 0
        endpointTimer?.invalidate()
        endpointTimer = nil
        cleanupAudio()
        request?.endAudio()
        task?.finish()
        deliverFinal()
    }

    /// Stops listening and drops what was heard (Mute in live talk): nothing
    /// half-said is sent.
    func discard() {
        guard isRecording else { return }
        transcript = ""
        stop()
    }

    private func deliverFinal() {
        let final = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        isRecording = false
        let failedNow = failed
        guard !final.isEmpty else {
            onListenEnded?(false, failedNow)
            return
        }
        transcript = ""
        onFinalTranscript?(final)
        onListenEnded?(true, false)
    }

    private func cleanupAudio() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        if !keepsSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

#else

// Voice input is iOS-only for now — it relies on AVAudioSession + the iOS mic
// permission flow. On macOS this is a no-op stub with the same surface so the
// mic button and its bindings compile unchanged; Mac users type. (Wiring real
// macOS dictation is a tracked follow-up.)
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var errorMessage: String?
    @Published var level: Double = 0

    var onFinalTranscript: ((String) -> Void)?
    var onListenEnded: ((_ heardWords: Bool, _ failed: Bool) -> Void)?
    var keepsSessionActive = false

    func toggle() {}
    func start() async {}
    func stop() {}
    func discard() {}
    func rebuildAudio() {}
}

#endif
