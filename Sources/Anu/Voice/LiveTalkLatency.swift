import Foundation
import os

/// How long live talk keeps the user waiting, one turn at a time: from their
/// last word to the first sound of Anu's answer, split where the time goes.
/// Pure, so it's tested with made-up clocks; `VoiceLoop` feeds it
/// `VoiceClock` milliseconds.
struct LiveTalkLatency: Equatable {
    struct Sample: Equatable {
        /// Last word → the listen ended (the endpointer's pause).
        let endpointMs: Int
        /// Listen ended → the answer's first words on screen.
        let firstWordsMs: Int?
        /// Listen ended → its first sentence handed to the voice.
        let firstSentenceMs: Int
        /// First sentence handed over → its first sound.
        let voiceMs: Int
        /// Last word → first sound: what the user feels.
        let totalMs: Int

        var summary: String {
            func s(_ ms: Int) -> String { String(format: "%.2f s", Double(ms) / 1000) }
            var parts = ["pause \(s(endpointMs))"]
            if let firstWordsMs { parts.append("first words \(s(firstWordsMs))") }
            parts += ["first sentence \(s(firstSentenceMs))", "voice \(s(voiceMs))", "total \(s(totalMs))"]
            return parts.joined(separator: " · ")
        }
    }

    private var spokeAt: Int?
    private var heardAt: Int?
    private var wordsAt: Int?
    private var queuedAt: Int?

    /// A listen ended with words: the user's last word was at `spokeAt`.
    mutating func heard(spokeAt: Int, endedAt: Int) {
        self = LiveTalkLatency()
        self.spokeAt = spokeAt >= 0 ? min(spokeAt, endedAt) : endedAt
        heardAt = endedAt
    }

    /// The answer's first words reached the screen.
    mutating func firstWords(at now: Int) {
        guard heardAt != nil, wordsAt == nil else { return }
        wordsAt = now
    }

    /// A sentence was handed to the voice; only this turn's first counts.
    mutating func sentenceQueued(at now: Int) {
        guard heardAt != nil, queuedAt == nil else { return }
        queuedAt = now
    }

    /// The voice made its first sound. Completes the turn's sample once.
    mutating func audioStarted(at now: Int) -> Sample? {
        guard let spokeAt, let heardAt, let queuedAt else { return nil }
        let sample = Sample(endpointMs: heardAt - spokeAt,
                            firstWordsMs: wordsAt.map { $0 - heardAt },
                            firstSentenceMs: queuedAt - heardAt,
                            voiceMs: max(now - queuedAt, 0),
                            totalMs: now - spokeAt)
        self = LiveTalkLatency()
        return sample
    }

    /// The turn was cut (barge-in, stop): it has no first sound to measure.
    mutating func cancel() { self = LiveTalkLatency() }

    var measuring: Bool { heardAt != nil }

    /// The middle value of a session's totals, for the report.
    static func median(_ samples: [Sample]) -> Int? {
        let totals = samples.map(\.totalMs).sorted()
        guard !totals.isEmpty else { return nil }
        let mid = totals.count / 2
        return totals.count % 2 == 1 ? totals[mid] : (totals[mid - 1] + totals[mid]) / 2
    }

    static let log = Logger(subsystem: "com.anu.app", category: "live-talk")
}
