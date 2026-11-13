import XCTest
@testable import Anu

/// Answers are checked against what the broker actually did (ADR-027).
final class ActionClaimsTests: XCTestCase {
    func testCompletedActionsAreClaims() {
        for answer in [
            "I've scheduled lunch with Maya for Thursday.",
            "I sent the text to Maya.",
            "Done! I’ve added it to your reminders.",
            "The invite has been sent.",
            "It's now on your calendar for 2 pm.",
            "I have successfully created the event.",
        ] {
            XCTAssertTrue(ActionClaims.claimsAction(answer), answer)
        }
    }

    func testProposalsAndFindsAreNotClaims() {
        for answer in [
            "I can schedule that for you — should I?",
            "I've found three free slots on Thursday.",
            "Would you like me to send it?",
            "Here's a draft you could send to Maya.",
            "Paris is the capital of France.",
        ] {
            XCTAssertFalse(ActionClaims.claimsAction(answer), answer)
        }
    }

    func testLeakedControlMarkupIsCaught() {
        XCTAssertTrue(ActionClaims.hasControlMarkup(#"<|tool_call>call:calendar{action: "list"}<tool_call|>"#))
        XCTAssertTrue(ActionClaims.hasControlMarkup(#"{"tool_call": {"name": "calendar""#))
        XCTAssertTrue(ActionClaims.hasControlMarkup("Sure<end_of_turn>"))
        XCTAssertFalse(ActionClaims.hasControlMarkup("Your next meeting is at 3 pm."))
        XCTAssertEqual(ActionClaims.strippingMarkup("Sure, here you go.<end_of_turn>"), "Sure, here you go.")
    }
}

/// The ReAct loop's one repair, driven with scripted model replies.
@MainActor
final class AnswerCheckTests: XCTestCase {
    private func orchestrator(_ replies: [String]) -> AgentOrchestrator {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("answer-\(UUID().uuidString)", isDirectory: true)
        let orch = AgentOrchestrator(model: QueuedMockModel(replies), sessionsDirectory: dir)
        orch.conversationHistory = [.user("Text Maya that I'm on my way")]
        orch.currentRunState = RunState(turnKey: "t")
        return orch
    }

    func testAClaimWithNoActionIsRepairedOnce() async {
        let orch = orchestrator([
            "I've sent the text to Maya.",
            "I haven't sent anything yet — want me to text Maya “On my way”?",
        ])
        await orch.reactLoop(startingIteration: 0)
        let last = orch.conversationHistory.last?.content ?? ""
        XCTAssertEqual(last, "I haven't sent anything yet — want me to text Maya “On my way”?")
        XCTAssertFalse(orch.conversationHistory.contains { $0.content.contains("I've sent the text") },
                       "the false claim is never kept")
    }

    func testAClaimThatSurvivesTheRepairIsMarked() async {
        let orch = orchestrator(["I've sent the text to Maya.", "I sent it to Maya."])
        await orch.reactLoop(startingIteration: 0)
        let last = orch.conversationHistory.last?.content ?? ""
        XCTAssertTrue(last.hasPrefix("I sent it to Maya."), last)
        XCTAssertTrue(last.hasSuffix(ActionClaims.notDoneWarning), last)
    }

    func testTheRepairNoteReachesTheModelButNotTheChat() async {
        let model = QueuedMockModel(["I've scheduled it.", "Shall I schedule it?"])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("answer-\(UUID().uuidString)")
        let orch = AgentOrchestrator(model: model, sessionsDirectory: dir)
        orch.conversationHistory = [.user("Lunch with Maya tomorrow")]
        orch.currentRunState = RunState(turnKey: "t")
        await orch.reactLoop(startingIteration: 0)
        XCTAssertEqual(model.capturedPrompts.count, 2)
        XCTAssertTrue(model.capturedPrompts[1].contains("you have not created, sent or changed anything yet"))
        XCTAssertFalse(orch.conversationHistory.contains { $0.content.contains("Note from Anu") })
    }
}

/// Memory claims (Android ADR-089), with Android's cases word for word,
/// including E4B's own answers from the emulator.
@MainActor
final class MemoryClaimTests: XCTestCase {
    func testSayingSomethingWasNotedOrWillBeRememberedIsAMemoryClaim() {
        let claims = [
            "I've noted that you typically buy oat milk every week. Is there anything else you'd like me to do with your notes or plans?",
            "I’ll remember that you buy oat milk every week.",
            "I've made a note of it.",
            "Noted!",
            "**Noted.** Anything else?",
            "Okay, noted.",
            "Duly noted.",
            "Thanks for telling me. Noted that you buy oat milk weekly.",
            "Got it, I'll keep that in mind.",
            "I'll keep in mind that you're vegan.",
            "I will remember your preference for mornings.",
            "I've saved that to your memory.",
            "I've added a new fact to your Memory tab.",
            "That's been noted.",
            "Your preference has been noted.",
            "I've booked lunch with Maya on Friday and noted that she's vegetarian.",
            "I'll add it to your calendar and keep in mind that you prefer mornings.",
            "Got it. I'll keep your weekend night shift schedule in mind for planning.",
            "I'll keep Alex's usual 6 PM finish time in mind for evening plans.",
        ]
        for text in claims { XCTAssertTrue(ActionClaims.claimsMemory(text), text) }
    }

    func testOtherUsesOfTheWordsAreNotClaims() {
        let notClaims = [
            "As you noted, the store closes at 5.",
            "As I've noted before, Friday is busy.",
            "Maya noted that the meeting moved to Friday.",
            "The email just says \"Noted, thanks.\"",
            "The noted chef opened a new place.",
            "Shall I remember that you buy oat milk every week?",
            "I can remember that for you if you like.",
            "Okay, I won't remember that.",
            "I remember that you're vegetarian, so here's a mushroom risotto.",
            "I don't have that in memory yet.",
            "Keep in mind that the store closes at 5.",
            "Please note that the meeting moved.",
            "I've added the event and noted the address in its description.",
            "Got it!",
        ]
        for text in notClaims { XCTAssertFalse(ActionClaims.claimsMemory(text), text) }
    }

    private func orchestrator(_ replies: [String]) -> AgentOrchestrator {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memclaim-\(UUID().uuidString)", isDirectory: true)
        let orch = AgentOrchestrator(model: QueuedMockModel(replies), sessionsDirectory: dir)
        orch.conversationHistory = [.user("I buy oat milk every week")]
        orch.currentRunState = RunState(turnKey: "t")
        return orch
    }

    func testAnUnbackedMemoryClaimIsRepairedOnce() async {
        let orch = orchestrator(["I've noted that you buy oat milk every week.", "Oat milk every week, sounds good."])
        await orch.reactLoop(startingIteration: 0)
        XCTAssertEqual(orch.conversationHistory.last?.content, "Oat milk every week, sounds good.")
        XCTAssertTrue(orch.reasoningSteps.contains { $0.thought == "The answer claimed a save to memory that didn't happen" })
    }

    func testAMemoryClaimThatSurvivesTheRepairIsMarked() async {
        let orch = orchestrator(["Noted!", "I'll remember that."])
        await orch.reactLoop(startingIteration: 0)
        let last = orch.conversationHistory.last?.content ?? ""
        XCTAssertTrue(last.hasSuffix(ActionClaims.notRememberedWarning), last)
    }

    func testAClaimOfBothIsMarkedForBoth() async {
        let orch = orchestrator(["I've booked lunch and noted that Maya is vegetarian.",
                                 "I've booked lunch and noted that Maya is vegetarian."])
        await orch.reactLoop(startingIteration: 0)
        let last = orch.conversationHistory.last?.content ?? ""
        XCTAssertTrue(last.hasSuffix(ActionClaims.notDoneOrRememberedWarning), last)
    }

    func testTheRepairNoteNamesTheToolOnlyWhenOffered() {
        let orch = orchestrator([])
        let note = orch.answerProblemNote("Noted!") ?? ""
        XCTAssertTrue(note.hasPrefix(ActionClaims.nothingRememberedNote), note)
        let offered = orch.toolsForCurrentTurn.contains { $0.name == ActionClaims.rememberTool }
        XCTAssertEqual(note.contains(ActionClaims.rememberHint), offered)
    }
}
