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
        /// End the listen now and send what was heard (the orb tapped mid-sentence).
        case finishListening
    }

    private(set) var active = false
    private(set) var quietListens = 0
    /// Muted from the Live Activity (ADR-108's iOS form): Anu still answers
    /// and speaks, but doesn't listen until unmuted.
    private(set) var muted = false
    /// A call or Siri has the audio: nothing listens until it gives it back.
    private(set) var paused = false

    static let callEndedNote = "Live talk stopped for a call. Tap the orb to talk again."

    mutating func start() -> Action {
        active = true
        quietListens = 0
        muted = false
        paused = false
        return .listen(afterMs: 0)
    }

    mutating func stop() {
        active = false
        quietListens = 0
        muted = false
        paused = false
    }

    /// The system took the audio (a call, Siri, an alarm).
    mutating func audioInterrupted() {
        guard active else { return }
        paused = true
    }

    /// The system gave the audio back. Listen again when it says to resume;
    /// otherwise (the user took the call) end, rather than sit there silent.
    mutating func audioResumed(shouldResume: Bool) -> Action {
        guard active, paused else { return .none }
        paused = false
        quietListens = 0
        if shouldResume { return muted ? .none : .listen(afterMs: Self.relistenDelayMs) }
        stop()
        return .end(note: Self.callEndedNote)
    }

    /// The orb was tapped. Speaking or thinking: stop and listen (a tap is a
    /// barge-in); listening: send what was heard now; otherwise listen.
    mutating func tapped(listening: Bool, speaking: Bool, thinking: Bool) -> Action {
        guard active else { return start() }
        if muted { return setMuted(false) }
        if speaking || thinking { return bargedIn() }
        if listening { return .finishListening }
        quietListens = 0
        return .listen(afterMs: 0)
    }

    /// Mutes or unmutes. Unmuting listens at once; muting is the caller's
    /// cue to stop the listen in progress.
    mutating func setMuted(_ on: Bool) -> Action {
        guard active, on != muted else { return .none }
        muted = on
        quietListens = 0
        return on ? .none : .listen(afterMs: 0)
    }

    /// A listen finished. With words, the chat sends them and waits for the
    /// answer; without, it listens again until four quiet listens in a row.
    mutating func listenEnded(heardWords: Bool, failed: Bool = false) -> Action {
        guard active else { return .none }
        // A listen stopped by muting, or by a call, isn't a quiet one.
        if (muted || paused) && !heardWords && !failed { return .none }
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
        guard active, !muted, !paused, !isThinking, !awaitingApproval, !isSpeaking else { return .none }
        return .listen(afterMs: Self.relistenDelayMs)
    }

    /// The user talked over Anu.
    mutating func bargedIn() -> Action {
        guard active, !muted, !paused else { return .none }
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
        /// End the listen without sending what was heard: half a sentence
        /// cut off by a call isn't a request.
        case discardListening
        /// Drop the listen and start it again on the new route (its input
        /// format changed under it).
        case restartListening
        case stopSpeaking
        /// End a voice note's recording, keeping what was recorded, marked cut short.
        case cutRecordingShort
        /// Live talk waits for the audio to come back.
        case pauseLiveTalk
        /// The audio came back; live talk resumes or ends (`LiveTalk.audioResumed`).
        case resumeLiveTalk(shouldResume: Bool)
        case reactivateSession
        /// Live talk listens again (its speech was cut by a route change).
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
            // A call or Siri took the audio: let go of everything, and send
            // nothing half-said.
            var out: [Effect] = []
            if state.liveTalk { out.append(.pauseLiveTalk) }
            if state.listening { out.append(.discardListening) }
            if state.speaking { out.append(.stopSpeaking) }
            if state.recordingNote { out.append(.cutRecordingShort) }
            return out
        case .interruptionEnded(let shouldResume):
            // Resume only when the system says so and the user was talking hands-free.
            guard state.liveTalk else { return [] }
            return shouldResume ? [.reactivateSession, .resumeLiveTalk(shouldResume: true)]
                                : [.resumeLiveTalk(shouldResume: false)]
        case .oldDeviceUnavailable:
            // Headphones pulled: don't carry on reading out loud from the
            // speaker (Apple's rule for spoken audio). In live talk the
            // conversation goes on: Anu listens on the new route.
            var out: [Effect] = []
            if state.speaking { out.append(.stopSpeaking) }
            if state.listening { out.append(.restartListening) }
            if state.liveTalk, state.speaking { out.append(.resumeListening) }
            return out
        case .newDeviceAvailable:
            // AirPods connected: the engines' formats changed, so a listen
            // starts again on them; speech already playing finishes where it is
            // only outside live talk (live talk's engine stops on the change).
            var out: [Effect] = []
            if state.listening { out.append(.restartListening) }
            if state.liveTalk, state.speaking { out += [.stopSpeaking, .resumeListening] }
            return out
        case .mediaServicesReset:
            var out: [Effect] = [.rebuildAudio]
            if state.recordingNote { out.insert(.cutRecordingShort, at: 0) }
            if state.listening { out.insert(.discardListening, at: 0) }
            if state.speaking { out.insert(.stopSpeaking, at: 0) }
            if state.liveTalk { out.append(.resumeListening) }
            return out
        }
    }
}

/// What the voice screen captions: the user's words and Anu's, from this
/// live talk only. Pure, so the rules are tested without a screen.
enum LiveTalkCaption {
    /// The user's words: what's being heard now, or, once the listen ended,
    /// the request it sent, until Anu answers the next one.
    static func heard(live: String, isListening: Bool, messages: [AgentMessage], since: Date) -> String? {
        if isListening {
            let words = live.trimmingCharacters(in: .whitespacesAndNewlines)
            return words.isEmpty ? nil : words
        }
        guard let last = messages.last(where: { $0.role == .user }), last.timestamp >= since else { return nil }
        let words = last.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }

    /// Anu's answer to the latest request, as it is read aloud: markdown
    /// dropped, and nothing while what streams is a tool call.
    static func answer(messages: [AgentMessage], since: Date) -> String? {
        let start = messages.lastIndex(where: { $0.role == .user }).map { $0 + 1 } ?? messages.startIndex
        guard start <= messages.endIndex,
              let reply = messages[start...].last(where: { $0.role == .assistant }),
              reply.timestamp >= since, !SpokenStream.looksLikeMarkup(reply.content) else { return nil }
        let spoken = SpokenSentences.speakable(reply.content)
        return spoken.isEmpty ? nil : spoken
    }
}

/// How answers sound in live talk: a few short spoken sentences, no markdown.
/// Goes with the newest message (per-message context, so the live chat's
/// opening, and Gemma's reuse of it, stay the same), for Gemma and Apple's model.
enum VoiceReplyStyle {
    static let hint = """
    The user is talking to you by voice and will hear your answer read aloud. Answer in one to \
    three short spoken sentences, the most useful first. No lists, headings, tables, emoji or \
    markdown. Say times, dates and numbers the way a person would say them.
    """

    /// The turn's context with the voice hint first, when the turn is spoken.
    static func context(_ memoryContext: String?, spoken: Bool) -> String? {
        guard spoken else { return memoryContext }
        guard let memoryContext, !memoryContext.isEmpty else { return hint }
        return hint + "\n\n" + memoryContext
    }
}
