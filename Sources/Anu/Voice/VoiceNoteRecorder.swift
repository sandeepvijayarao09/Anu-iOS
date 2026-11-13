import Foundation
#if os(iOS)
import AVFoundation
#endif

/// Collects converted audio off the real-time thread. Thread-safe.
final class PCMAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    let maxBytes: Int

    init(maxSeconds: Int = VoiceRecording.maxSeconds, sampleRate: Int = VoiceRecording.speechRate) {
        maxBytes = maxSeconds * sampleRate * 2
    }

    /// Appends, and says whether the limit is reached.
    @discardableResult
    func append(_ bytes: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let room = maxBytes - data.count
        if room > 0 { data.append(bytes.prefix(room)) }
        return data.count >= maxBytes
    }

    var byteCount: Int { lock.lock(); defer { lock.unlock() }; return data.count }

    func take() -> Data {
        lock.lock(); defer { lock.unlock() }
        let out = data
        data = Data()
        return out
    }
}

#if os(iOS)
/// Records a voice note from the microphone as mono 16 kHz 16-bit PCM, in
/// memory, up to five minutes (Android ADR-078). The level drives the orb.
/// When iOS takes the microphone (a call, Siri) or the user leaves Anu, the
/// recording ends there, is kept, and is marked as stopped early.
@MainActor
final class VoiceNoteRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var level: Double = 0
    @Published private(set) var seconds = 0

    var onFinished: ((VoiceRecording) -> Void)?
    var onError: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var accumulator = PCMAccumulator()
    private var interruptionObserver: NSObjectProtocol?

    func start() async {
        guard !isRecording else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            onError?("Voice notes need Microphone access. Turn it on in Settings › Anu.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true, options: [])

            let input = engine.inputNode
            let inFormat = input.outputFormat(forBus: 0)
            guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
                  let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(VoiceRecording.speechRate),
                                                channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
                throw TranscriptionError.unavailable("No microphone input")
            }
            accumulator = PCMAccumulator()
            let sink = accumulator
            input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
                let amplitude = SpeechRecognizer.normalizedAmplitude(of: buffer)
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
                var full = false
                if error == nil, let channel = out.int16ChannelData?[0] {
                    full = sink.append(Data(bytes: channel, count: Int(out.frameLength) * 2))
                }
                let secs = sink.byteCount / 2 / VoiceRecording.speechRate
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    self.level += (amplitude - self.level) * (amplitude > self.level ? 0.45 : 0.12)
                    self.seconds = secs
                    if full { self.finish() }
                }
            }
            engine.prepare()
            try engine.start()
            isRecording = true
            seconds = 0
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: session, queue: .main
            ) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor [weak self] in self?.cutShort() }
            }
        } catch {
            teardown()
            onError?(SpeechRecognizer.describe(error))
        }
    }

    /// Ends the recording, keeping it.
    func finish() { end(interrupted: false, keep: true) }

    /// Ends the recording, keeping it, marked as stopped early.
    func cutShort() { end(interrupted: true, keep: true) }

    /// Throws the recording away.
    func cancel() { end(interrupted: false, keep: false) }

    private func end(interrupted: Bool, keep: Bool) {
        guard isRecording else { return }
        isRecording = false
        teardown()
        let pcm = accumulator.take()
        level = 0
        guard keep, !pcm.isEmpty else { return }
        onFinished?(VoiceRecording(pcm: pcm, interrupted: interrupted))
    }

    private func teardown() {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#else
/// macOS: voice notes are recorded on iPhone and iPad for now.
@MainActor
final class VoiceNoteRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var level: Double = 0
    @Published private(set) var seconds = 0
    var onFinished: ((VoiceRecording) -> Void)?
    var onError: ((String) -> Void)?

    func start() async { onError?("Voice notes are recorded on iPhone and iPad.") }
    func finish() {}
    func cutShort() {}
    func cancel() {}
}
#endif
