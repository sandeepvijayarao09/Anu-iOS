import Foundation

// Voice notes (Android G3, EXP-3, ADR-078). "+" → Voice note records on the
// phone; the note is written down on the device (Gemma 4's audio input through
// LiteRT-LM when the loaded model can hear, else Apple's on-device speech
// recognition), and only its words are kept, with the message. A voice note
// never goes to the cloud: while one is in the model's view, the turn stays on
// the device and every cloud escalation is refused before any ledger entry.

/// What the thread keeps of a voice note: its kind, length and words. Never
/// the audio.
struct VoiceNoteInfo: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Recorded in Anu by the user.
        case own
        /// Shared from another app: it can hold other people's words.
        case shared
    }

    var kind: Kind
    var seconds: Int
    var transcript: String
    /// Words the user typed with the note, if any.
    var typed: String?
    /// The recording ended early (a call, Siri, leaving Anu).
    var interrupted = false
    /// Which engine wrote it down ("Gemma 4 on this device", "Apple speech recognition").
    var engine: String?
    /// How long writing it down took.
    var transcribeMillis: Int?

    var lengthLabel: String { VoiceNoteFormat.duration(seconds) }
    var title: String { kind == .shared ? "Shared recording · \(lengthLabel)" : "Voice note · \(lengthLabel)" }
}

enum VoiceNoteFormat {
    /// "0:17", "4:05".
    static func duration(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// Rules for voice notes in a turn.
enum VoiceNotePolicy {
    /// The words the model reads for a voice note turn.
    static func modelText(for note: VoiceNoteInfo) -> String {
        let typed = note.typed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let words = note.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        switch note.kind {
        case .own:
            body = "My voice note (\(note.lengthLabel)), written down on this device: \(words)"
        case .shared:
            body = "A recording shared with me (\(note.lengthLabel)), which can hold other people's words, written down on this device: \(words)"
        }
        return typed.isEmpty ? body : "\(typed)\n\n\(body)"
    }

    /// Whether the model's view holds a voice note, which keeps the turn on the device.
    static func keepsOnDevice(_ messages: [AgentMessage]) -> Bool {
        messages.contains { $0.voiceNote != nil }
    }

    /// Tools that send the conversation to a cloud model.
    static let cloudTools: Set<String> = ["escalate_to_gemini", "escalate_to_private_cloud"]

    /// A refusal for a cloud escalation while a voice note is in view, or nil.
    static func refusal(forTool name: String, history: [AgentMessage]) -> String? {
        guard cloudTools.contains(name), keepsOnDevice(history) else { return nil }
        return "This conversation holds a voice note, and voice notes never leave this device, so nothing was sent to the cloud. Answer on the device."
    }

    /// What the user sees when a recording held no words.
    static let nothingSaid = "Nothing was said in this recording."
}

/// Cleans what a transcriber returned.
enum VoiceNoteTranscript {
    /// The words only. "[no speech]" (the model's answer for silence and
    /// noise) becomes empty.
    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        if lowered.contains("[no speech]") || lowered == "no speech" || lowered == "no speech." {
            return ""
        }
        for prefix in ["transcript:", "transcription:"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        if text.count >= 2, let first = text.first, let last = text.last,
           (first == "\"" && last == "\"") || (first == "\u{201C}" && last == "\u{201D}") {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The prompt Gemma gets with each piece of a recording.
    static let prompt = "Write down the words spoken in this recording, in the language they are spoken in. Reply with the words only. If nobody speaks, reply [no speech]."

    /// Gemma reads at most this many seconds of audio at once.
    static let pieceSeconds = 30

    /// Splits `samples` into pieces of at most `maxSeconds`, each cut at the
    /// quietest 100 ms in the last quarter before its limit (greedy), so a cut
    /// falls between words rather than through one. Returns sample ranges.
    static func pieces(_ samples: [Int16], sampleRate: Int, maxSeconds: Int = pieceSeconds) -> [Range<Int>] {
        let limit = max(sampleRate * maxSeconds, 1)
        guard samples.count > limit else { return samples.isEmpty ? [] : [0..<samples.count] }
        let frame = max(sampleRate / 10, 1)
        var out: [Range<Int>] = []
        var start = 0
        while samples.count - start > limit {
            let hardEnd = start + limit
            let searchFrom = start + limit * 3 / 4
            var bestCut = hardEnd
            var bestEnergy = Double.infinity
            var at = searchFrom
            while at + frame <= hardEnd {
                var energy = 0.0
                for k in at..<(at + frame) { let v = Double(samples[k]); energy += v * v }
                if energy < bestEnergy { bestEnergy = energy; bestCut = at + frame / 2 }
                at += frame
            }
            out.append(start..<bestCut)
            start = bestCut
        }
        out.append(start..<samples.count)
        return out
    }
}
