import AVFoundation
import XCTest
@testable import Anu

/// Speech through the voice-processing engine (barge-in, ADR-129), without a
/// speaker or microphone: the playback bookkeeping, buffer conversion, routing,
/// and rebuilding the audio after a media-services reset.
@MainActor
final class EngineSpeechTests: XCTestCase {

    // MARK: Playback bookkeeping

    func testAnUtteranceFinishesOnlyWhenWrittenAndEveryBufferPlayed() {
        var playback = SpeechPlayback()
        let a = playback.enqueue()
        XCTAssertEqual(playback.scheduled(a), [.started])
        XCTAssertEqual(playback.scheduled(a), [], "started once per stretch")
        XCTAssertEqual(playback.played(a), [], "still rendering")
        XCTAssertEqual(playback.written(a), [], "one buffer still playing")
        XCTAssertEqual(playback.played(a), [.utteranceFinished, .allFinished])
        XCTAssertTrue(playback.isIdle)
        XCTAssertFalse(playback.playing)
    }

    func testQueuedUtterancesFinishInOrderAndAllFinishedComesOnceAtTheEnd() {
        var playback = SpeechPlayback()
        let a = playback.enqueue()
        let b = playback.enqueue()
        _ = playback.scheduled(a)
        _ = playback.scheduled(b)
        XCTAssertEqual(playback.written(b), [])
        XCTAssertEqual(playback.played(b), [], "the second can't finish before the first")
        XCTAssertEqual(playback.written(a), [])
        XCTAssertEqual(playback.played(a), [.utteranceFinished, .utteranceFinished, .allFinished])
    }

    func testABlankUtteranceFinishesAtOnceAndStopIgnoresLateCallbacks() {
        var playback = SpeechPlayback()
        let a = playback.enqueue()
        XCTAssertEqual(playback.written(a), [.utteranceFinished, .allFinished])

        let b = playback.enqueue()
        _ = playback.scheduled(b)
        playback.cancelAll()
        XCTAssertTrue(playback.isIdle)
        XCTAssertEqual(playback.played(b), [], "a buffer from before the stop")
        XCTAssertEqual(playback.written(b), [])
    }

    // MARK: Buffers

    private func tone(format: AVAudioFormat, frames: AVAudioFrameCount, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let value = amplitude * sinf(Float(i) * 2 * .pi * 440 / Float(format.sampleRate))
            if let ints = buffer.int16ChannelData { ints[0][i] = Int16(value * Float(Int16.max)) }
            if let floats = buffer.floatChannelData { floats[0][i] = value }
        }
        return buffer
    }

    func testSynthesizerBuffersConvertToThePlayersFormat() throws {
        // AVSpeechSynthesizer.write commonly gives 16-bit mono at 22.05 kHz.
        let int16 = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 22_050, channels: 1, interleaved: false))
        let player = PCMConversion.playerFormat()
        let out = try XCTUnwrap(PCMConversion.convert(tone(format: int16, frames: 2_205), to: player))
        XCTAssertEqual(out.format, player)
        XCTAssertEqual(Int(out.frameLength), 2_205, accuracy: 64)
        XCTAssertGreaterThan(PCMConversion.level(out), 0.5, "a loud tone stays loud")

        let fast = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let resampled = try XCTUnwrap(PCMConversion.convert(tone(format: player, frames: 2_205), to: fast))
        XCTAssertEqual(Int(resampled.frameLength), 4_800, accuracy: 128, "100 ms at either rate")
    }

    func testAnEmptyBufferIsTheEndNotSound() throws {
        let player = PCMConversion.playerFormat()
        let empty = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: player, frameCapacity: 16))
        XCTAssertNil(PCMConversion.convert(empty, to: player))
        let same = tone(format: player, frames: 100)
        XCTAssertTrue(PCMConversion.convert(same, to: player) === same, "already in format: no copy")
    }

    func testSpeechLevel() {
        let quiet = [Float](repeating: 0, count: 64)
        let loud = [Float](repeating: 0.5, count: 64)
        quiet.withUnsafeBufferPointer { XCTAssertEqual(SpeechLevel.of($0), 0) }
        loud.withUnsafeBufferPointer { XCTAssertEqual(SpeechLevel.of($0), 1) }
        [Float]().withUnsafeBufferPointer { XCTAssertEqual(SpeechLevel.of($0), 0) }
    }

    // MARK: Routing

    func testOnlyLiveTalkWithTheMicrophoneSpeaksThroughTheEngine() {
        XCTAssertTrue(SpeechSynthesizer.routesThroughEngine(conversational: true, available: true, speakingDirectly: false))
        XCTAssertFalse(SpeechSynthesizer.routesThroughEngine(conversational: false, available: true, speakingDirectly: false),
                       "read-aloud outside live talk plays the ordinary way")
        XCTAssertFalse(SpeechSynthesizer.routesThroughEngine(conversational: true, available: false, speakingDirectly: false),
                       "voice processing needs the microphone")
        XCTAssertFalse(SpeechSynthesizer.routesThroughEngine(conversational: true, available: true, speakingDirectly: true),
                       "never on top of speech already playing")
    }

    func testWithoutTheMicrophoneSpeechStillPlaysTheOrdinaryWay() {
        // The simulator has no microphone permission: live talk falls back.
        let tts = SpeechSynthesizer()
        tts.conversational = true
        tts.enqueue("Hello")
        XCTAssertTrue(tts.isSpeaking)
        tts.stop()
        XCTAssertFalse(tts.isSpeaking)
        tts.rebuildAudio()
        XCTAssertFalse(tts.isSpeaking)
    }

    // MARK: Media services reset

    func testAMediaServicesResetRebuildsTheAudio() {
        let loop = VoiceLoop()
        var calls: [String] = []
        loop.isSpeaking = { true }
        loop.isListening = { true }
        loop.stopSpeech = { calls.append("stopSpeech") }
        loop.stopListening = { calls.append("stopListening") }
        loop.rebuildAudio = { calls.append("rebuild") }
        loop.handle(.mediaServicesReset)
        XCTAssertEqual(calls, ["stopSpeech", "stopListening", "rebuild"], "let go of the dead objects, then build new ones")

        calls = []
        loop.handle(.interruptionBegan)
        XCTAssertFalse(calls.contains("rebuild"), "an interruption doesn't rebuild")
    }
}
