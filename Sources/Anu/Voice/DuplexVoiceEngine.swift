import Foundation
#if os(iOS)
import AVFoundation

/// One AVAudioEngine for live talk (ADR-129): its input node has voice
/// processing on, and Anu's speech plays on a player node in the same engine,
/// so Apple's echo canceller has Anu's own voice as its reference and the
/// barge-in detector hears only the user. The decisions are in pure types
/// (`SpeechPlayback`, `BargeInDetector`); this class is the thin I/O around
/// them, and it only runs on a device with a microphone.
@MainActor
final class DuplexVoiceEngine {
    static let shared = DuplexVoiceEngine()

    /// Playback events, on the main actor.
    var onEvent: ((SpeechPlayback.Event) -> Void)?
    /// How loud the speech just played is, 0...1.
    var onLevel: ((Double) -> Void)?

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var synthesizer = AVSpeechSynthesizer()
    private var playback = SpeechPlayback()
    private let format = PCMConversion.playerFormat()
    private var wired = false
    private var micTapped = false
    /// Bumped by every stop and rebuild, so callbacks from before are ignored.
    private var generation = 0

    var isRunning: Bool { engine.isRunning }
    var isSpeaking: Bool { !playback.isIdle }

    /// Whether speech can go through the engine: voice processing needs the
    /// microphone, so without its permission speech plays the ordinary way.
    static var available: Bool { AVAudioApplication.shared.recordPermission == .granted }

    // MARK: Speaking

    /// Renders `utterance` and plays it after anything queued. False when the
    /// engine couldn't start; the caller then speaks the ordinary way.
    func speak(_ utterance: AVSpeechUtterance) -> Bool {
        guard Self.available, ensureRunning() else { return false }
        let id = playback.enqueue()
        let generation = self.generation
        let format = self.format
        synthesizer.write(utterance) { [weak self] buffer in
            // The synthesizer's queue: convert here, then hand the main actor a copy.
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            let converted = pcm.frameLength == 0 ? nil : PCMConversion.convert(pcm, to: format).map(PCMBox.init)
            let finished = pcm.frameLength == 0
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                if let converted { self.schedule(converted.buffer, utterance: id) }
                if finished { self.emit(self.playback.written(id)) }
            }
        }
        return true
    }

    /// Stops speech at once and drops everything queued.
    func stopSpeaking() {
        generation += 1
        synthesizer.stopSpeaking(at: .immediate)
        player.stop()
        let wasSpeaking = !playback.isIdle
        playback.cancelAll()
        if wasSpeaking { onEvent?(.allFinished) }
        releaseIfIdle()
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, utterance id: Int) {
        let level = PCMConversion.level(buffer)
        let generation = self.generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.onLevel?(level)
                self.emit(self.playback.played(id))
            }
        }
        emit(playback.scheduled(id))
        if !player.isPlaying { player.play() }
    }

    private func emit(_ events: [SpeechPlayback.Event]) {
        for event in events { onEvent?(event) }
        if events.contains(.allFinished) { releaseIfIdle() }
    }

    // MARK: Listening (barge-in)

    /// Measures the echo-cancelled microphone while Anu speaks. The handler
    /// runs on the audio thread and gets each buffer's samples, which are
    /// never kept.
    func startMic(_ handler: @escaping @Sendable (UnsafeBufferPointer<Float>) -> Void) -> Bool {
        guard Self.available, ensureRunning(), !micTapped else { return micTapped }
        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0 else { return false }
        input.installTap(onBus: 0, bufferSize: 512, format: micFormat) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            handler(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        micTapped = true
        return true
    }

    var micSampleRate: Double { engine.inputNode.outputFormat(forBus: 0).sampleRate }

    func stopMic() {
        guard micTapped else { return }
        engine.inputNode.removeTap(onBus: 0)
        micTapped = false
        releaseIfIdle()
    }

    // MARK: Engine

    private func ensureRunning() -> Bool {
        if engine.isRunning { return true }
        do {
            if !wired {
                // Voice processing first: it changes the I/O unit, and both
                // directions then run through Apple's echo canceller.
                try engine.inputNode.setVoiceProcessingEnabled(true)
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                wired = true
            }
            engine.prepare()
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    /// Lets go of the microphone and the I/O unit once nothing is playing or
    /// listening, so dictation can open its own.
    private func releaseIfIdle() {
        guard playback.isIdle, !micTapped, engine.isRunning else { return }
        player.stop()
        engine.stop()
    }

    /// After the media server restarts every audio object is dead: build new
    /// ones (Apple's guidance for `mediaServicesWereResetNotification`).
    func rebuild() {
        generation += 1
        let wasSpeaking = !playback.isIdle
        playback.cancelAll()
        if micTapped { engine.inputNode.removeTap(onBus: 0) }
        micTapped = false
        engine.stop()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        synthesizer = AVSpeechSynthesizer()
        wired = false
        if wasSpeaking { onEvent?(.allFinished) }
    }
}

/// Carries a converted buffer from the synthesizer's queue to the main actor;
/// nothing else touches it in between.
private struct PCMBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}
#endif
