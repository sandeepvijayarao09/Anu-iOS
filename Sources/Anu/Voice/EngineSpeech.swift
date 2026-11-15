import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

// Speech played through Anu's own audio engine (ADR-129, barge-in).
//
// Apple's echo canceller removes from the microphone only what the same
// voice-processing I/O unit plays. AVSpeechSynthesizer.speak plays through the
// system's own path, so the canceller had no reference and the barge-in
// detector heard Anu's own voice. In live talk Anu now renders speech with
// AVSpeechSynthesizer.write and plays the buffers on an AVAudioPlayerNode in
// the same AVAudioEngine whose input node has voice processing on
// (`DuplexVoiceEngine`). The bookkeeping below is pure so it's tested without
// a speaker or a microphone.

/// Tracks utterances rendered into buffers and played: an utterance is done
/// once its synthesis has finished and every buffer it gave has played.
struct SpeechPlayback: Equatable {
    enum Event: Equatable {
        /// The first buffer of an idle stretch began playing.
        case started
        /// One utterance has finished playing.
        case utteranceFinished
        /// Nothing is left to play.
        case allFinished
    }

    private struct Utterance: Equatable {
        let id: Int
        var scheduled = 0
        var played = 0
        var written = false
        var done: Bool { written && played >= scheduled }
    }

    private var queue: [Utterance] = []
    private var nextID = 0
    private(set) var playing = false

    var isIdle: Bool { queue.isEmpty }
    var pending: Int { queue.count }

    /// A new utterance was handed to the synthesizer; returns its id.
    mutating func enqueue() -> Int {
        nextID += 1
        queue.append(Utterance(id: nextID))
        return nextID
    }

    /// A buffer of utterance `id` was scheduled on the player.
    mutating func scheduled(_ id: Int) -> [Event] {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return [] }
        queue[i].scheduled += 1
        guard !playing else { return [] }
        playing = true
        return [.started]
    }

    /// A buffer of utterance `id` finished playing.
    mutating func played(_ id: Int) -> [Event] {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return [] }
        queue[i].played += 1
        return settle()
    }

    /// The synthesizer finished rendering utterance `id` (its empty buffer).
    mutating func written(_ id: Int) -> [Event] {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return [] }
        queue[i].written = true
        return settle()
    }

    /// Everything was stopped: late callbacks for old ids are ignored.
    mutating func cancelAll() {
        queue = []
        playing = false
    }

    private mutating func settle() -> [Event] {
        var events: [Event] = []
        // Utterances play in order, so only the head can finish.
        while let head = queue.first, head.done {
            queue.removeFirst()
            events.append(.utteranceFinished)
        }
        if queue.isEmpty, playing || !events.isEmpty {
            playing = false
            events.append(.allFinished)
        }
        return events
    }
}

/// How loud a buffer of speech is, 0...1, for the orb's pulse.
enum SpeechLevel {
    static func of(_ samples: UnsafeBufferPointer<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for s in samples { sum += Double(s) * Double(s) }
        let rms = (sum / Double(samples.count)).squareRoot()
        return min(1, rms * 6)
    }
}

#if canImport(AVFoundation)
/// Turns the synthesizer's buffers (often 16-bit at 22.05 kHz, depending on
/// the voice) into the player's format.
enum PCMConversion {
    /// The format the speech player is connected with: mono float. The mixer
    /// resamples it to the hardware rate.
    static func playerFormat(sampleRate: Double = 22_050) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    }

    /// `buffer` in `format`, or nil when it can't be converted. The same buffer
    /// when it's already in that format.
    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if given {
                inputStatus.pointee = .endOfStream
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }

    /// The first channel's samples as floats, for measuring.
    static func level(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        return SpeechLevel.of(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
#endif
