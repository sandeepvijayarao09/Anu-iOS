import Foundation
#if os(iOS)
import AVFoundation
import Speech
#endif

/// Splits a stream of samples into fixed 20 ms chunks and reports each
/// chunk's level on the barge-in scale. Pure, so it's tested without a mic.
struct ChunkLevels {
    let chunkSize: Int
    private var sumSquares = 0.0
    private var count = 0

    init(sampleRate: Double) {
        chunkSize = max(Int(sampleRate * BargeInDetector.chunkSeconds), 1)
    }

    /// Takes float samples (-1...1); returns the levels of every chunk completed.
    mutating func push(_ samples: UnsafeBufferPointer<Float>) -> [Double] {
        var out: [Double] = []
        for sample in samples {
            sumSquares += Double(sample) * Double(sample)
            count += 1
            if count == chunkSize {
                out.append(BargeInDetector.level(rms: (sumSquares / Double(count)).squareRoot()))
                sumSquares = 0
                count = 0
            }
        }
        return out
    }
}

#if os(iOS)
/// Listens for the user talking over Anu while it speaks in voice mode
/// (ADR-129). The voice-processing input (Apple's echo canceller) feeds the
/// pure `BargeInDetector` 20 ms at a time; each chunk is only measured for
/// loudness, then dropped. It fires `onBargeIn` once.
@MainActor
final class BargeInMonitor {
    var onBargeIn: (() -> Void)?
    private(set) var isRunning = false
    private var engine = AVAudioEngine()
    /// The engine Anu's speech plays through in live talk. When it's running,
    /// the microphone is read from it, so the echo canceller removes Anu's own
    /// voice; otherwise a separate voice-processing engine is the fallback.
    var duplex: DuplexVoiceEngine? = .shared
    private var onDuplex = false

    func start() {
        guard !isRunning else { return }
        guard AVAudioApplication.shared.recordPermission == .granted else { return }
        if let duplex, duplex.isRunning, duplex.isSpeaking {
            let box = DetectorBox(sampleRate: duplex.micSampleRate)
            let started = duplex.startMic { [weak self] samples in
                guard box.push(samples) else { return }
                Task { @MainActor [weak self] in self?.fire() }
            }
            if started {
                onDuplex = true
                isRunning = true
                return
            }
        }
        let input = engine.inputNode
        // Without echo cancellation the bar would sit on Anu's own voice;
        // the detector's calibration makes it fail quiet either way.
        try? input.setVoiceProcessingEnabled(true)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        let box = DetectorBox(sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let fired = box.push(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            if fired {
                Task { @MainActor [weak self] in self?.fire() }
            }
        }
        do {
            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    private func fire() {
        guard isRunning else { return }
        stop()
        onBargeIn?()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if onDuplex {
            onDuplex = false
            duplex?.stopMic()
            return
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        // A fresh engine each time: the input format can change with the route.
        engine = AVAudioEngine()
    }

    /// After a media-services reset: drop the dead engine for a new one.
    func rebuild() {
        stop()
        engine = AVAudioEngine()
    }
}

/// The detector and chunker, owned by the audio thread.
private final class DetectorBox: @unchecked Sendable {
    private var chunks: ChunkLevels
    private var detector = BargeInDetector()
    private var fired = false

    init(sampleRate: Double) { chunks = ChunkLevels(sampleRate: sampleRate) }

    func push(_ samples: UnsafeBufferPointer<Float>) -> Bool {
        guard !fired else { return false }
        for level in chunks.push(samples) where detector.push(level) {
            fired = true
            return true
        }
        return false
    }
}

/// One round of on-device recognition for the wake phrase: listens until the
/// recognizer finalizes, a pause, or `maxSeconds`, and returns what it heard.
/// Server recognition is never used.
@MainActor
final class WakeRecognizerRound {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    /// New for every round: one from before a media-services reset is dead.
    private var engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<WakeRound, Never>?
    private var heard = ""
    private var lastChange = 0
    private var timer: Timer?

    var maxSeconds = 8
    var pauseMs = 1_200

    func listen() async -> WakeRound {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVAudioApplication.shared.recordPermission == .granted else {
            return .failed("Hey Anu needs Microphone and Speech Recognition access.", fatal: true)
        }
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            return .failed("On-device speech recognition isn't available, so Hey Anu can't listen.", fatal: true)
        }
        guard recognizer.isAvailable else { return .failed("Speech recognition is busy.") }
        return await withCheckedContinuation { cont in
            continuation = cont
            begin(recognizer)
        }
    }

    func cancel() { finish(.silence) }

    private func begin(_ recognizer: SFSpeechRecognizer) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true, options: [])
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            self.request = request
            engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            engine.prepare()
            try engine.start()
            let started = VoiceClock.nowMs()
            lastChange = started
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let text, text != self.heard { self.heard = text; self.lastChange = VoiceClock.nowMs() }
                    if isFinal || failed { self.finishHeard() }
                }
            }
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let now = VoiceClock.nowMs()
                    let paused = !self.heard.isEmpty && now - self.lastChange >= self.pauseMs
                    if paused || now - started >= self.maxSeconds * 1000 { self.finishHeard() }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } catch {
            finish(.failed(SpeechRecognizer.describe(error)))
        }
    }

    private func finishHeard() {
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        finish(text.isEmpty ? .silence : .heard(text))
    }

    private func finish(_ round: WakeRound) {
        timer?.invalidate()
        timer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        heard = ""
        // Never kept: the words are dropped here unless they woke Anu.
        let cont = continuation
        continuation = nil
        cont?.resume(returning: round)
    }
}
#endif
