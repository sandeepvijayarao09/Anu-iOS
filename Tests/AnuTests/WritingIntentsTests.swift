import XCTest
@testable import Anu

/// Tests the bounded headless completion that backs the Writing Tools intents
/// (Summarize / Rewrite / Proofread) and the inline "Ask Anu" intent. Uses a
/// hermetic orchestrator with a queued mock model — no real inference.
@MainActor
final class WritingIntentsTests: XCTestCase {

    private func makeOrch(_ responses: [String]) -> AgentOrchestrator {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wi-\(UUID().uuidString)", isDirectory: true)
        return AgentOrchestrator(model: QueuedMockModel(responses), sessionsDirectory: dir)
    }

    func testCompleteHeadlessReturnsModelText() async {
        let orch = makeOrch(["A concise summary."])
        let out = await orch.completeHeadless(system: "Summarize.", user: "a long piece of text")
        XCTAssertEqual(out, "A concise summary.")
    }

    func testCompleteHeadlessLeavesChatUntouched() async {
        let orch = makeOrch(["the answer"])
        _ = await orch.completeHeadless(system: "Rewrite.", user: "make this nicer")
        // No conversational bubbles are created by the headless path.
        XCTAssertFalse(orch.messages.contains { $0.role == .user })
        XCTAssertFalse(orch.messages.contains { $0.role == .assistant })
        XCTAssertTrue(orch.conversationHistory.isEmpty)
        XCTAssertFalse(orch.isThinking)
    }

    func testCompleteHeadlessFoldsSystemAndUserIntoPrompt() async {
        let model = QueuedMockModel(["ok"])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wi-\(UUID().uuidString)", isDirectory: true)
        let orch = AgentOrchestrator(model: model, sessionsDirectory: dir)
        _ = await orch.completeHeadless(system: "SENTINEL_SYSTEM", user: "SENTINEL_USER")
        let prompt = model.capturedPrompts.last ?? ""
        XCTAssertTrue(prompt.contains("SENTINEL_SYSTEM"), prompt)
        XCTAssertTrue(prompt.contains("SENTINEL_USER"), prompt)
    }

    func testPresentGeneratedImageAddsAssistantImageBubble() async {
        let orch = makeOrch([])
        orch.presentGeneratedImage(Data([0x1, 0x2, 0x3]), caption: "a sunset")
        let last = orch.messages.last
        XCTAssertEqual(last?.role, .assistant)
        XCTAssertEqual(last?.content, "a sunset")
        XCTAssertNotNil(last?.imageData)
    }
}
