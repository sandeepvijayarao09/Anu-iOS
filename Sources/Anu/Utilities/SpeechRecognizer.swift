import Foundation
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
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
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
                    if error != nil {
                        // Recognition ended (silence timeout etc.) — treat
                        // whatever we have as final
                        self.stop()
                    }
                }
            }
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
            cleanupAudio()
        }
    }

    func stop() {
        guard isRecording else { return }
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
