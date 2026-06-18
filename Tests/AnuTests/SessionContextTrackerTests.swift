import XCTest
@testable import Anu

final class SessionContextTrackerTests: XCTestCase {

    func testFreshTrackerResets() {
        let tracker = SessionContextTracker()
        XCTAssertEqual(tracker.feed(for: "<start_of_turn>user\nHi<end_of_turn>\n<start_of_turn>model\n"), .reset)
    }

    func testContinuingConversationAppendsDelta() {
        var tracker = SessionContextTracker()
        let turn1 = "<start_of_turn>user\nHi<end_of_turn>\n<start_of_turn>model\n"
        tracker.didSend(fullPrompt: turn1)
        tracker.didGenerate("Hey! How's it going?")

        // Next templated prompt: previous prompt + assistant turn + new user turn
        let turn2 = turn1 + "Hey! How's it going?<end_of_turn>\n"
            + "<start_of_turn>user\nGood!<end_of_turn>\n<start_of_turn>model\n"

        guard case .append(let delta) = tracker.feed(for: turn2) else {
            return XCTFail("expected an append")
        }
        XCTAssertEqual(delta, "<start_of_turn>user\nGood!<end_of_turn>\n<start_of_turn>model\n")
    }

    func testGenerationRecordingTrimsWhitespace() {
        var tracker = SessionContextTracker()
        tracker.didSend(fullPrompt: "P")
        tracker.didGenerate("  answer \n")
        XCTAssertEqual(tracker.seenText, "Panswer<end_of_turn>\n")
    }

    func testDivergentPromptResets() {
        var tracker = SessionContextTracker()
        tracker.didSend(fullPrompt: "old conversation")
        XCTAssertEqual(tracker.feed(for: "completely new conversation"), .reset)
    }

    func testClearedConversationResets() {
        var tracker = SessionContextTracker()
        tracker.didSend(fullPrompt: "something")
        tracker.reset()
        XCTAssertEqual(tracker.feed(for: "something else entirely"), .reset)
    }
}
