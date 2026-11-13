import XCTest
@testable import Anu

/// Live talk, barge-in decisions, early first clause, and audio-session
/// interruption/route handling — all without a microphone.
@MainActor
final class VoiceLoopTests: XCTestCase {

    // MARK: LiveTalk policy

    func testListensAgainAfterSpeakingAndEndsAfterFourQuietListens() {
        var talk = LiveTalk()
        XCTAssertEqual(talk.start(), .listen(afterMs: 0))
        XCTAssertEqual(talk.listenEnded(heardWords: true), .none)
        XCTAssertEqual(talk.answerDone(isThinking: false, awaitingApproval: false, isSpeaking: false),
                       .listen(afterMs: LiveTalk.relistenDelayMs))
        XCTAssertEqual(talk.answerDone(isThinking: true, awaitingApproval: false, isSpeaking: false), .none)
        XCTAssertEqual(talk.answerDone(isThinking: false, awaitingApproval: true, isSpeaking: false), .none)
        XCTAssertEqual(talk.answerDone(isThinking: false, awaitingApproval: false, isSpeaking: true), .none)
        for _ in 0..<3 { XCTAssertEqual(talk.listenEnded(heardWords: false), .listen(afterMs: 0)) }
        guard case .end = talk.listenEnded(heardWords: false) else { return XCTFail("four quiet listens end it") }
        XCTAssertFalse(talk.active)
        XCTAssertEqual(talk.listenEnded(heardWords: false), .none)
    }

    func testWordsResetTheQuietCountAndBargeInInterrupts() {
        var talk = LiveTalk()
        _ = talk.start()
        _ = talk.listenEnded(heardWords: false)
        _ = talk.listenEnded(heardWords: false)
        _ = talk.listenEnded(heardWords: true)
        XCTAssertEqual(talk.quietListens, 0)
        XCTAssertEqual(talk.bargedIn(), .interrupt)
        talk.stop()
        XCTAssertEqual(talk.bargedIn(), .none)
    }

    func testAFailedListenEndsLiveTalkInsteadOfLooping() {
        var talk = LiveTalk()
        _ = talk.start()
        guard case .end = talk.listenEnded(heardWords: false, failed: true) else { return XCTFail() }
        XCTAssertFalse(talk.active)
    }

    // MARK: Audio session policy

    func testInterruptionLetsGoOfEverythingAndResumesOnlyWhenAsked() {
        let busy = VoiceSessionPolicy.State(liveTalk: true, listening: true, speaking: true, recordingNote: true)
        XCTAssertEqual(VoiceSessionPolicy.effects(of: .interruptionBegan, state: busy),
                       [.stopListening, .stopSpeaking, .cutRecordingShort])
        let idle = VoiceSessionPolicy.State(liveTalk: true, listening: false, speaking: false, recordingNote: false)
        XCTAssertEqual(VoiceSessionPolicy.effects(of: .interruptionEnded(shouldResume: true), state: idle),
                       [.reactivateSession, .resumeListening])
        XCTAssertEqual(VoiceSessionPolicy.effects(of: .interruptionEnded(shouldResume: false), state: idle), [])
        var notLive = idle
        notLive.liveTalk = false
        XCTAssertEqual(VoiceSessionPolicy.effects(of: .interruptionEnded(shouldResume: true), state: notLive), [])
    }

    func testHeadphonesPulledStopsSpeech() {
        let speaking = VoiceSessionPolicy.State(liveTalk: false, listening: false, speaking: true, recordingNote: false)
        XCTAssertEqual(VoiceSessionPolicy.effects(of: .oldDeviceUnavailable, state: speaking), [.stopSpeaking])
        XCTAssertEqual(VoiceSessionPolicy.effects(of: .newDeviceAvailable, state: speaking), [])
        XCTAssertEqual(VoiceSessionPolicy.effects(of: .mediaServicesReset, state: speaking), [.stopSpeaking, .rebuildAudio])
    }

    // MARK: VoiceLoop wiring

    private final class Rig {
        var spoken: [String] = []
        var listens = 0
        var stops = 0
        var cancels = 0
        var thinking = false
        var speaking = false
        var listening = false
        var approval = false
        var speakAnswers = true
    }

    private func loop(_ rig: Rig) -> VoiceLoop {
        let loop = VoiceLoop()
        loop.enqueueSpeech = { rig.spoken.append($0); rig.speaking = true }
        loop.stopSpeech = { rig.stops += 1; rig.speaking = false }
        loop.startListening = { rig.listens += 1; rig.listening = true }
        loop.stopListening = { rig.listening = false }
        loop.cancelAnswer = { rig.cancels += 1 }
        loop.isThinking = { rig.thinking }
        loop.isSpeaking = { rig.speaking }
        loop.isListening = { rig.listening }
        loop.awaitingApproval = { rig.approval }
        loop.shouldSpeak = { rig.speakAnswers }
        loop.after = { _, work in work() }   // no real waiting in tests
        return loop
    }

    func testFirstClauseIsSpokenWhileTheRestStreams() {
        let rig = Rig()
        let voice = loop(rig)
        voice.turnStarted(at: Date(timeIntervalSince1970: 0))
        var answer = AgentMessage.assistant("Your next meeting is with Maya", isStreaming: true)
        rig.thinking = true
        voice.observe(answer, isThinking: true)
        XCTAssertEqual(rig.spoken, [])
        answer.content += " at three, and after"
        voice.observe(answer, isThinking: true)
        XCTAssertEqual(rig.spoken, ["Your next meeting is with Maya at three,"])
        answer.content += " that you're free"
        answer.isStreaming = false
        rig.thinking = false
        voice.observe(answer, isThinking: false)
        XCTAssertEqual(rig.spoken, ["Your next meeting is with Maya at three,", "and after that you're free"])
    }

    func testOldMessagesAndMutedRepliesAreNotSpoken() {
        let rig = Rig()
        let voice = loop(rig)
        let old = AgentMessage(role: .assistant, content: "Earlier answer.", timestamp: Date(timeIntervalSince1970: 0))
        voice.turnStarted(at: Date(timeIntervalSince1970: 100))
        voice.observe(old, isThinking: false)
        XCTAssertEqual(rig.spoken, [])

        rig.speakAnswers = false
        voice.turnStarted(at: Date(timeIntervalSince1970: 0))
        voice.observe(.assistant("Fresh answer."), isThinking: false)
        XCTAssertEqual(rig.spoken, [], "spoken replies off and not in voice mode")
    }

    func testLiveTalkListensAgainAfterTheAnswerIsSpoken() {
        let rig = Rig()
        rig.speakAnswers = false   // voice mode speaks regardless
        let voice = loop(rig)
        voice.startLiveTalk()
        XCTAssertEqual(rig.listens, 1)
        rig.listening = false
        voice.listenEnded(heardWords: true, failed: false)
        voice.turnStarted(at: Date(timeIntervalSince1970: 0))
        rig.thinking = true
        voice.observe(.assistant("It's sunny."), isThinking: true)
        XCTAssertEqual(rig.spoken, ["It's sunny."])
        rig.thinking = false
        voice.turnEnded()
        XCTAssertEqual(rig.listens, 1, "still speaking: don't listen over it")
        rig.speaking = false
        voice.speechFinished()
        XCTAssertEqual(rig.listens, 2)
    }

    func testBargeInStopsSpeechAndTheAnswerThenListens() {
        let rig = Rig()
        let voice = loop(rig)
        voice.startLiveTalk()
        rig.listening = false
        rig.speaking = true
        rig.thinking = true
        voice.bargedIn()
        XCTAssertEqual(rig.stops, 1)
        XCTAssertEqual(rig.cancels, 1)
        XCTAssertEqual(rig.listens, 2)
    }

    func testNoRelistenWhileAnApprovalWaits() {
        let rig = Rig()
        let voice = loop(rig)
        voice.startLiveTalk()
        rig.listening = false
        rig.approval = true
        voice.turnEnded()
        XCTAssertEqual(rig.listens, 1)
    }

    func testFourQuietListensEndLiveTalkWithANote() {
        let rig = Rig()
        let voice = loop(rig)
        voice.startLiveTalk()
        for _ in 0..<4 {
            rig.listening = false
            voice.listenEnded(heardWords: false, failed: false)
        }
        XCTAssertFalse(voice.liveTalk.active)
        XCTAssertNotNil(voice.notice)
        XCTAssertEqual(rig.listens, 4)
    }

    func testInterruptionStopsListeningAndSpeaking() {
        let rig = Rig()
        let voice = loop(rig)
        voice.startLiveTalk()
        rig.speaking = true
        voice.handle(.interruptionBegan)
        XCTAssertFalse(rig.listening)
        XCTAssertEqual(rig.stops, 1)
        voice.handle(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(rig.listens, 2)
    }
}
