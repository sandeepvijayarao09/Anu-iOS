import Foundation

/// Hands-free voice mode as decisions, not audio (Android ADR-101, ADR-129):
/// Anu listens, sends what it heard at a pause, reads its answer aloud, and
/// listens again by itself shortly after it stops speaking. Talking over it
/// stops the speech and listens at once. Four listens in a row that hear
/// nothing end it. `VoiceLoop` turns these actions into audio calls.
struct LiveTalk: Equatable {
    static let relistenDelayMs = 400
    static let maxQuietListens = 4

    enum Action: Equatable {
        case none
        /// Start listening after this many milliseconds.
        case listen(afterMs: Int)
        /// Stop speaking and whatever answer is still being written, then listen.
        case interrupt
        /// Leave live talk, with a note for the user.
        case end(note: String)
    }

    private(set) var active = false
    private(set) var quietListens = 0

    mutating func start() -> Action {
        active = true
        quietListens = 0
        return .listen(afterMs: 0)
    }

    mutating func stop() {
        active = false
        quietListens = 0
    }

    /// A listen finished. With words, the chat sends them and waits for the
    /// answer; without, it listens again until four quiet listens in a row.
    mutating func listenEnded(heardWords: Bool, failed: Bool = false) -> Action {
        guard active else { return .none }
        if failed {
            stop()
            return .end(note: "Voice isn't available right now.")
        }
        if heardWords {
            quietListens = 0
            return .none
        }
        quietListens += 1
        if quietListens >= Self.maxQuietListens {
            stop()
            return .end(note: "Voice mode paused after a few quiet moments. Tap the orb to talk again.")
        }
        return .listen(afterMs: 0)
    }

    /// Anu finished (or never started) speaking its answer. Listen again,
    /// unless it is still thinking or waiting on the user's approval.
    func answerDone(isThinking: Bool, awaitingApproval: Bool, isSpeaking: Bool) -> Action {
        guard active, !isThinking, !awaitingApproval, !isSpeaking else { return .none }
        return .listen(afterMs: Self.relistenDelayMs)
    }

    /// The user talked over Anu.
    mutating func bargedIn() -> Action {
        guard active else { return .none }
        quietListens = 0
        return .interrupt
    }
}

/// What the voice code should do about an audio-session event. Pure so the
/// interruption and route rules are unit-tested; `VoiceLoop` maps
/// AVAudioSession notifications onto these inputs.
enum VoiceSessionPolicy {
    enum Event: Equatable {
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        /// The old output went away (headphones unplugged, Bluetooth dropped).
        case oldDeviceUnavailable
        case newDeviceAvailable
        /// The media server restarted; every audio object is invalid.
        case mediaServicesReset
    }

    enum Effect: Equatable {
        case stopListening
        case stopSpeaking
        /// End a voice note's recording, keeping what was recorded, marked cut short.
        case cutRecordingShort
        case reactivateSession
        case resumeListening
        /// Rebuild the audio engines.
        case rebuildAudio
    }

    struct State: Equatable {
        var liveTalk: Bool
        var listening: Bool
        var speaking: Bool
        var recordingNote: Bool
    }

    static func effects(of event: Event, state: State) -> [Effect] {
        switch event {
        case .interruptionBegan:
            // A call or Siri took the audio: let go of everything.
            var out: [Effect] = []
            if state.listening { out.append(.stopListening) }
            if state.speaking { out.append(.stopSpeaking) }
            if state.recordingNote { out.append(.cutRecordingShort) }
            return out
        case .interruptionEnded(let shouldResume):
            // Resume only when the system says so and the user was talking hands-free.
            guard shouldResume, state.liveTalk else { return [] }
            return [.reactivateSession, .resumeListening]
        case .oldDeviceUnavailable:
            // Headphones pulled: don't carry on reading out loud from the
            // speaker (Apple's rule for spoken audio).
            return state.speaking ? [.stopSpeaking] : []
        case .newDeviceAvailable:
            return []
        case .mediaServicesReset:
            var out: [Effect] = [.rebuildAudio]
            if state.recordingNote { out.insert(.cutRecordingShort, at: 0) }
            if state.listening { out.insert(.stopListening, at: 0) }
            if state.speaking { out.insert(.stopSpeaking, at: 0) }
            return out
        }
    }
}
