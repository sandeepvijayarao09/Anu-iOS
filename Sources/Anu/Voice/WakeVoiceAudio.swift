import Foundation
import OSLog
#if os(iOS)
import AVFoundation
#endif

/// Cuts 16 kHz audio, as the converter hands it over in any size, into
/// `WakeAudio.chunk`-sample chunks. Holds less than one chunk between calls.
struct WakeChunker {
    private var pending: [Int16] = []

    mutating func add(_ samples: [Int16]) -> [[Int16]] {
        pending += samples
        var chunks: [[Int16]] = []
        while pending.count >= WakeAudio.chunk {
            chunks.append(Array(pending.prefix(WakeAudio.chunk)))
            pending.removeFirst(WakeAudio.chunk)
        }
        return chunks
    }

    mutating func reset() { pending.removeAll() }
}

/// One stretch of listening with the user's voice, as the loop sees it.
enum WakeVoiceRound: Equatable {
    case woke
    /// The microphone wouldn't open, or stopped.
    case micFailed(String)
    case cancelled
}

/// "Hey Anu" from the user's samples, as Android's WakeDetector runs it: the
/// microphone stays open and each 80 ms is matched (`WakeVoiceListener`); a
/// wake opens Anu with no request, since nothing transcribed one, and voice
/// mode listens for it. A microphone that won't open is tried again after a
/// pause, doubling each time; after `maxFailures` in a row it stops.
struct WakeVoiceLoop {
    var maxFailures = 5
    var backoffMs = 2_000

    let listen: () async -> WakeVoiceRound
    /// Waits, in milliseconds. Throws when cancelled.
    let sleep: (Int) async throws -> Void

    func run(onWake: () async -> Bool) async -> WakeLoop.Stop {
        var failures = 0
        do {
            while true {
                if Task.isCancelled { return .cancelled }
                switch await listen() {
                case .cancelled:
                    return .cancelled
                case .micFailed(let reason):
                    failures += 1
                    if failures >= maxFailures { return .failed(reason) }
                    try await sleep(backoffMs << (failures - 1))
                case .woke:
                    failures = 0
                    if !(await onWake()) { return .cantOpen }
                }
            }
        } catch {
            return .cancelled
        }
    }
}

/// Matches 80 ms chunks against the user's voice: features, then the matcher,
/// then the trigger. Not thread-safe; the listener feeds it from one queue.
final class WakeVoiceMatcher {
    private let features: WakeFeatures
    private var matcher: WakeMatcher
    private var trigger: WakeTrigger
    private let log = Logger(subsystem: "com.anu.app", category: "HeyAnu")

    init(voice: WakeVoice, features: WakeFeatures = LogMelFeatures()) {
        self.features = features
        matcher = WakeMatcher(voice: voice)
        trigger = WakeTrigger(threshold: voice.threshold)
    }

    /// Whether this chunk completed a wake.
    func push(_ chunk: [Int16]) -> Bool {
        let distance = matcher.push(features.push(chunk))
        let threshold = trigger.threshold
        switch trigger.push(distance) {
        case .woke(let best)?:
            // Distances only, never audio, and only in debug builds' logs.
            log.debug("Hey Anu: woke at \(best, format: .fixed(precision: 3)), threshold \(threshold, format: .fixed(precision: 3))")
            reset()
            return true
        case .nearMiss(let nearest)?:
            log.debug("Hey Anu: near miss at \(nearest, format: .fixed(precision: 3)), threshold \(threshold, format: .fixed(precision: 3))")
            return false
        case nil:
            return false
        }
    }

    func reset() {
        features.reset()
        matcher.reset()
        trigger.reset()
    }
}

#if os(iOS)
/// The microphone as 16 kHz mono 16-bit audio in 80 ms chunks, for "Hey Anu"
/// and for its enrollment: an AVAudioEngine tap, converted as voice notes'
/// recorder converts it. Chunks arrive on a private serial queue; nothing is
/// kept beyond the chunk being cut.
final class WakeMic {
    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.anu.wake.mic")
    private var running = false

    /// Opens the microphone; `onChunk` runs on the mic's queue for each chunk.
    func start(onChunk: @escaping ([Int16]) -> Void) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true, options: [])
        engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(WakeAudio.rate),
                                            channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw TranscriptionError.unavailable("No microphone input")
        }
        var chunker = WakeChunker()
        let queue = self.queue
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { buffer, _ in
            let ratio = outFormat.sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = out.int16ChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            queue.async {
                for chunk in chunker.add(samples) { onChunk(chunk) }
            }
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// One `WakeVoiceRound`: listens on the microphone until the user's "Hey Anu"
/// matches, the microphone fails, or `cancel`.
@MainActor
final class WakeVoiceListener {
    private let voice: WakeVoice
    private let mic = WakeMic()
    private var continuation: CheckedContinuation<WakeVoiceRound, Never>?
    private var interruption: NSObjectProtocol?
    private var cancelled = false

    init(voice: WakeVoice) { self.voice = voice }

    func listen() async -> WakeVoiceRound {
        if cancelled || Task.isCancelled { return .cancelled }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            return .micFailed("Hey Anu needs Microphone access. Turn it on in Settings › Anu.")
        }
        return await withCheckedContinuation { cont in
            continuation = cont
            let matcher = WakeVoiceMatcher(voice: voice)
            do {
                try mic.start { [weak self] chunk in
                    guard matcher.push(chunk) else { return }
                    Task { @MainActor [weak self] in self?.finish(.woke) }
                }
                interruption = NotificationCenter.default.addObserver(
                    forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main
                ) { [weak self] note in
                    let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                    Task { @MainActor [weak self] in self?.finish(.micFailed("The microphone is in use.")) }
                }
            } catch {
                finish(.micFailed(SpeechRecognizer.describe(error)))
            }
        }
    }

    func cancel() {
        cancelled = true
        finish(.cancelled)
    }

    private func finish(_ round: WakeVoiceRound) {
        // Closes the microphone before Anu opens.
        mic.stop()
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        interruption = nil
        let cont = continuation
        continuation = nil
        cont?.resume(returning: round)
    }
}

/// Records one enrollment sample: opens the microphone, feeds each chunk to
/// `WakeEnrollmentModel`, and stops when it says the user stopped talking.
@MainActor
final class WakeSampleRecorder {
    private let mic = WakeMic()
    private var recording = false

    func record(into model: WakeEnrollmentModel) async {
        guard !recording else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            model.failed("Teaching Anu your voice needs Microphone access. Turn it on in Settings › Anu.")
            return
        }
        recording = true
        model.began()
        do {
            try mic.start { [weak self, weak model] chunk in
                Task { @MainActor [weak self, weak model] in
                    guard let self, let model, self.recording else { return }
                    if model.add(chunk) { self.stop(model) }
                }
            }
        } catch {
            recording = false
            model.failed(SpeechRecognizer.describe(error))
        }
    }

    func stop(_ model: WakeEnrollmentModel) {
        guard recording else { return }
        recording = false
        mic.stop()
        model.finished()
    }

    /// Leaves without checking the sample.
    func cancel(_ model: WakeEnrollmentModel) {
        guard recording else { return }
        recording = false
        mic.stop()
        model.failed("")
    }
}
#endif
