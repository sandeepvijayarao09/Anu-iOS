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
                       [.pauseLiveTalk, .discardListening, .stopSpeaking, .cutRecordingShort],
                       "half a sentence cut off by a call is never sent")
        let idle = VoiceSessionPolicy.State(liveTalk: true, listening: false, speaking: false, recordingNote: false)
        XCTAssertEqual(VoiceSessionPolicy.effects(of: .interruptionEnded(shouldResume: true), state: idle),
                       [.reactivateSession, .resumeLiveTalk(shouldResume: true)])
        XCTAssertEqual(VoiceSessionPolicy.effects(of: .interruptionEnded(shouldResume: false), state: idle),
                       [.resumeLiveTalk(shouldResume: false)], "live talk must end, not sit silent")
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
        var discards = 0
        var restarts = 0
        var finishes = 0
        var thinking = false
        var speaking = false
        var listening = false
        var approval = false
        var speakAnswers = true
        var now = 0
        var heard = (spokeAt: -1, endedAt: -1)
    }

    private func loop(_ rig: Rig) -> VoiceLoop {
        let loop = VoiceLoop()
        loop.enqueueSpeech = { rig.spoken.append($0); rig.speaking = true }
        loop.stopSpeech = { rig.stops += 1; rig.speaking = false }
        loop.startListening = { rig.listens += 1; rig.listening = true }
        loop.stopListening = { rig.finishes += 1; rig.listening = false }
        loop.discardListening = { rig.discards += 1; rig.listening = false }
        loop.restartListening = { rig.restarts += 1 }
        loop.clock = { rig.now }
        loop.lastHeard = { rig.heard }
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

    // MARK: Calls, routes and taps (live talk keeps going, or ends saying why)

    func testACallMidListenSendsNothingAndEndsLiveTalkIfTheUserTookIt() {
        let rig = Rig()
        let voice = loop(rig)
        voice.startLiveTalk()
        voice.handle(.interruptionBegan)
        XCTAssertEqual(rig.discards, 1, "the half-heard words are dropped, not sent")
        XCTAssertTrue(voice.liveTalk.paused)
        // The dropped listen reports in: no new listen during the call, and
        // it isn't counted as a quiet one.
        voice.listenEnded(heardWords: false, failed: false)
        XCTAssertEqual(rig.listens, 1)
        XCTAssertEqual(voice.liveTalk.quietListens, 0)
        voice.handle(.interruptionEnded(shouldResume: false))
        XCTAssertFalse(voice.liveTalk.active)
        XCTAssertEqual(voice.notice, LiveTalk.callEndedNote)
    }

    func testHeadphonesPulledWhileSpeakingStopsAndListensAgain() {
        let rig = Rig()
        let voice = loop(rig)
        voice.startLiveTalk()
        rig.listening = false
        rig.speaking = true
        voice.handle(.oldDeviceUnavailable)
        XCTAssertEqual(rig.stops, 1)
        XCTAssertEqual(rig.listens, 2, "the conversation goes on, on the speaker")
    }

    func testAirPodsConnectingRestartsTheListenOnThem() {
        let rig = Rig()
        let voice = loop(rig)
        voice.startLiveTalk()
        voice.handle(.newDeviceAvailable)
        XCTAssertEqual(rig.restarts, 1)
        XCTAssertEqual(VoiceSessionPolicy.effects(of: .newDeviceAvailable, state: .init(
            liveTalk: true, listening: false, speaking: true, recordingNote: false)), [.stopSpeaking, .resumeListening])
    }

    func testTapRules() {
        var talk = LiveTalk()
        XCTAssertEqual(talk.tapped(listening: false, speaking: false, thinking: false), .listen(afterMs: 0),
                       "a tap after live talk paused starts it again")
        XCTAssertTrue(talk.active)
        XCTAssertEqual(talk.tapped(listening: false, speaking: true, thinking: false), .interrupt)
        XCTAssertEqual(talk.tapped(listening: false, speaking: false, thinking: true), .interrupt)
        XCTAssertEqual(talk.tapped(listening: true, speaking: false, thinking: false), .finishListening)
        _ = talk.setMuted(true)
        XCTAssertEqual(talk.tapped(listening: false, speaking: true, thinking: false), .listen(afterMs: 0))
        XCTAssertFalse(talk.muted, "a tap while muted unmutes")
    }

    func testTappingWhileAnuSpeaksStopsItAndListens() {
        let rig = Rig()
        let voice = loop(rig)
        voice.startLiveTalk()
        rig.listening = false
        rig.speaking = true
        voice.tapped()
        XCTAssertEqual(rig.stops, 1)
        XCTAssertEqual(rig.listens, 2, "Stop must not leave the loop waiting")
        voice.tapped()
        XCTAssertEqual(rig.finishes, 1, "a tap while listening sends what was heard")
    }

    // MARK: Latency

    func testLatencyRunsFromTheLastWordToTheFirstSound() {
        let rig = Rig()
        let voice = loop(rig)
        voice.startLiveTalk()
        rig.listening = false
        rig.heard = (spokeAt: 1_000, endedAt: 1_700)
        rig.now = 1_700
        voice.listenEnded(heardWords: true, failed: false)
        voice.turnStarted(at: Date(timeIntervalSince1970: 0))
        rig.thinking = true
        rig.now = 2_000
        voice.observe(.assistant("Sure, it's", isStreaming: true), isThinking: true)
        rig.now = 2_300
        voice.observe(.assistant("Sure, it's three o'clock.", isStreaming: true), isThinking: true)
        XCTAssertEqual(rig.spoken, ["Sure, it's three o'clock."])
        rig.now = 2_450
        voice.audioStarted()
        XCTAssertEqual(voice.lastLatency, LiveTalkLatency.Sample(
            endpointMs: 700, firstWordsMs: 300, firstSentenceMs: 600, voiceMs: 150, totalMs: 1_450))
        // Later sentences of the same answer aren't a new measurement.
        rig.now = 3_000
        voice.audioStarted()
        XCTAssertEqual(voice.latencies.count, 1)
    }

    func testABargeInOrAnApprovalIsNotMeasured() {
        let rig = Rig()
        let voice = loop(rig)
        voice.startLiveTalk()
        rig.listening = false
        rig.heard = (spokeAt: 100, endedAt: 800)
        voice.listenEnded(heardWords: true, failed: false)
        rig.thinking = true
        voice.approvalAsked()
        XCTAssertEqual(rig.spoken, ["I need your OK on the screen first."])
        voice.audioStarted()
        XCTAssertNil(voice.lastLatency, "waiting on the user isn't Anu's latency")
    }

    func testLatencyMedian() {
        func sample(_ total: Int) -> LiveTalkLatency.Sample {
            .init(endpointMs: 0, firstWordsMs: nil, firstSentenceMs: 0, voiceMs: 0, totalMs: total)
        }
        XCTAssertNil(LiveTalkLatency.median([]))
        XCTAssertEqual(LiveTalkLatency.median([sample(900), sample(1_500), sample(1_100)]), 1_100)
        XCTAssertEqual(LiveTalkLatency.median([sample(1_000), sample(2_000)]), 1_500)
    }

    // MARK: Sentence streaming with tools

    func testAToolCallIsNeverReadAndTheAnswerAfterItIs() {
        let rig = Rig()
        let voice = loop(rig)
        voice.startLiveTalk()
        voice.turnStarted(at: Date(timeIntervalSince1970: 0))
        rig.thinking = true
        var call = AgentMessage.assistant(#"{"tool_call": {"name": "set_timer""#, isStreaming: true)
        voice.observe(call, isThinking: true)
        call.isStreaming = false
        voice.observe(call, isThinking: true)
        XCTAssertEqual(rig.spoken, [])
        voice.observe(.assistant("Your timer is set for ten minutes.", isStreaming: true), isThinking: true)
        XCTAssertEqual(rig.spoken, ["Your timer is set for ten minutes."])
    }

    // MARK: Captions and spoken style

    func testCaptionsShowThisTalkOnlyAndReadLikeSpeech() {
        let opened = Date(timeIntervalSince1970: 100)
        let before = AgentMessage(role: .user, content: "old question", timestamp: Date(timeIntervalSince1970: 0))
        let oldAnswer = AgentMessage(role: .assistant, content: "Old answer.", timestamp: Date(timeIntervalSince1970: 1))
        XCTAssertNil(LiveTalkCaption.heard(live: "", isListening: false, messages: [before, oldAnswer], since: opened))
        XCTAssertNil(LiveTalkCaption.answer(messages: [before, oldAnswer], since: opened))
        XCTAssertEqual(LiveTalkCaption.heard(live: "what's on ", isListening: true, messages: [before], since: opened),
                       "what's on")

        let asked = AgentMessage(role: .user, content: "what's on my calendar", timestamp: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(LiveTalkCaption.heard(live: "", isListening: false, messages: [before, oldAnswer, asked], since: opened),
                       "what's on my calendar", "the request stays up while Anu thinks")
        XCTAssertNil(LiveTalkCaption.answer(messages: [before, oldAnswer, asked], since: opened),
                     "the last answer isn't this request's")
        let call = AgentMessage(role: .assistant, content: #"{"tool_call": {}}"#, timestamp: Date(timeIntervalSince1970: 201))
        XCTAssertNil(LiveTalkCaption.answer(messages: [asked, call], since: opened))
        let reply = AgentMessage(role: .assistant, content: "**Dentist** at [3 pm](x://y).", timestamp: Date(timeIntervalSince1970: 202))
        XCTAssertEqual(LiveTalkCaption.answer(messages: [asked, call, reply], since: opened), "Dentist at 3 pm.")
    }

    func testTheSpokenHintGoesWithTheNewestMessageOnly() throws {
        XCTAssertNil(VoiceReplyStyle.context(nil, spoken: false))
        XCTAssertEqual(VoiceReplyStyle.context("[M1] likes tea", spoken: false), "[M1] likes tea")
        XCTAssertEqual(VoiceReplyStyle.context(nil, spoken: true), VoiceReplyStyle.hint)
        XCTAssertEqual(VoiceReplyStyle.context("[M1] likes tea", spoken: true), VoiceReplyStyle.hint + "\n\n[M1] likes tea")

        // Gemma's reuse: the opening and older turns read the same with or
        // without the hint, so the live chat isn't read again.
        let chat = [AgentMessage.user("hi"), .assistant("Hello."), .user("what's the time")]
        let spoken = GemmaChatTemplate.format(messages: chat, tools: [], memoryContext: VoiceReplyStyle.context(nil, spoken: true),
                                              now: Date(timeIntervalSince1970: 0))
        let typed = GemmaChatTemplate.format(messages: chat, tools: [], now: Date(timeIntervalSince1970: 0))
        let newest = try XCTUnwrap(spoken.range(of: "<start_of_turn>user\n", options: .backwards))
        let typedNewest = try XCTUnwrap(typed.range(of: "<start_of_turn>user\n", options: .backwards))
        XCTAssertEqual(spoken[..<newest.lowerBound], typed[..<typedNewest.lowerBound])
        XCTAssertTrue(spoken[newest.upperBound...].contains("read aloud"))
    }

    func testAnInstantAnswerIsSpokenAndTheTurnEndsOnce() {
        let rig = Rig()
        let voice = loop(rig)
        voice.startLiveTalk()
        rig.listening = false
        voice.listenEnded(heardWords: true, failed: false)
        // The send marks the turn; the answer lands before any frame passes.
        voice.turnStarted()
        voice.turnStartedIfNeeded()   // the thinking flag, late: no reset
        voice.observe(.assistant("15 times 3 is 45."), isThinking: false)
        XCTAssertEqual(rig.spoken, ["15 times 3 is 45."])
        rig.speaking = false
        voice.turnEnded()
        voice.turnEnded()             // reported twice, acted on once
        XCTAssertEqual(rig.listens, 2)
    }
}
