import XCTest
@testable import GemmaAgent

@MainActor
final class CriticTests: XCTestCase {

    func testApproved() async {
        let v = await Critic(model: QueuedMockModel([#"{"verdict":"approved"}"#]))
            .review(goal: "g", draft: "d", scratchpad: Scratchpad())
        XCTAssertEqual(v, .approved)
    }

    func testRevise() async {
        let v = await Critic(model: QueuedMockModel([#"{"verdict":"revise","instruction":"add a concrete example"}"#]))
            .review(goal: "g", draft: "d", scratchpad: Scratchpad())
        XCTAssertEqual(v, .revise(instruction: "add a concrete example"))
    }

    func testAmbiguousDefaultsToApproved() async {
        let v = await Critic(model: QueuedMockModel(["hmm, hard to say honestly"]))
            .review(goal: "g", draft: "d", scratchpad: Scratchpad())
        XCTAssertEqual(v, .approved)
    }

    // MARK: - Pure parser

    func testParseReviseWithoutInstructionApproves() {
        // "revise" with no actionable fix isn't worth a round-trip.
        XCTAssertEqual(Critic.parse(#"{"verdict":"revise"}"#), .approved)
    }

    func testParseApproved() {
        XCTAssertEqual(Critic.parse("```json\n{\"verdict\":\"approved\"}\n```"), .approved)
    }
}
