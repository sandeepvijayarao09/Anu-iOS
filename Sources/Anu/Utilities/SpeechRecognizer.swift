import Foundation

#if os(iOS)
import Speech
import AVFoundation

/// Voice-first input: on-device speech recognition streaming a live
/// transcript. Tap to start, tap to stop; the final transcript is handed
/// to `onFinalTranscript` (the chat auto-sends it).
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

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() {
        if isRecording {
            stop()
        } else {
            Task { await start() }
        }
    }

    func start() async {
        errorMessage = nil
        transcript = ""

        let speechAuth = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard speechAuth == .authorized else {
            errorMessage = "Voice input needs Speech Recognition access. Enable it in Settings › Anu, or just type instead."
            return
        }
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else {
            errorMessage = "Voice input needs Microphone access. Enable it in Settings › Anu, or just type instead."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition unavailable"
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true // privacy: never leaves the device
            }
            self.request = request

            let inputNode = audioEngine.inputNode
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

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        if result.isFinal {
                            self.deliverFinal()
                        }
                    }
                    if let error {
                        // Recognition ended. A silence timeout after real
                        // speech is routine — surface nothing and send what we
                        // have. Dying with an empty transcript means the mic
                        // never delivered audio, which the user needs told.
                        if self.transcript.trimmingCharacters(in: .whitespaces).isEmpty {
                            self.errorMessage = Self.describe(error)
                        }
                        self.stop()
                    }
                }
            }
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
            cleanupAudio()
        }
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

    func stop() {
        guard isRecording else { return }
        level = 0
        cleanupAudio()
        request?.endAudio()
        task?.finish()
        deliverFinal()
    }

    private func deliverFinal() {
        let final = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        isRecording = false
        guard !final.isEmpty else { return }
        transcript = ""
        onFinalTranscript?(final)
    }

    private func cleanupAudio() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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

    func toggle() {}
    func start() async {}
    func stop() {}
}

#endif
