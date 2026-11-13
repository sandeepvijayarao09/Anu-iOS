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
