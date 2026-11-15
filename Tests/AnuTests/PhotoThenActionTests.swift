import XCTest
@testable import Anu

/// On device: a camera question, then "Set an alarm for 8 am tomorrow". The
/// photo kept the turn on the tool-less chat, and Apple's model said the
/// alarm was set. Three fixes, each locked in here.
@MainActor
final class PhotoThenActionTests: XCTestCase {
    private func photo() -> Data {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        return Data(base64Encoded: png)!
    }

    private func orchestrator(_ model: QueuedMockModel) -> AgentOrchestrator {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("photo-action-\(UUID().uuidString)", isDirectory: true)
        return AgentOrchestrator(model: model, sessionsDirectory: dir)
    }

    private func lastRoute(_ orch: AgentOrchestrator) -> String? {
        orch.reasoningSteps.last { $0.action?.hasPrefix("Route →") == true }?.action
    }

    func testADeviceRequestAfterAPhotoGetsTools() async {
        let model = QueuedMockModel(["It's a keyboard.", "Which list should it go on?"])
        let orch = orchestrator(model)
        await orch.run(userMessage: "What's this?", attachments: MessageAttachments(photos: [photo()]))
        XCTAssertTrue(orch.hasMediaInView)

        await orch.run(userMessage: "remind me to buy a new keyboard")
        XCTAssertEqual(lastRoute(orch), "Route → \(ModelRoute.onDeviceAgent.displayName)")
    }

    func testAChatAnswerThatClaimsAnActionSaysNothingWasDone() async {
        let model = QueuedMockModel(["Done — your alarm’s set. You good?"])
        let orch = orchestrator(model)
        await orch.run(userMessage: "hey, how's it going")
        let answer = orch.messages.last { $0.role == .assistant }?.content ?? ""
        XCTAssertTrue(answer.hasSuffix(ActionClaims.notDoneWarning), answer)
    }

    func testAnOrdinaryChatAnswerIsLeftAlone() async {
        let model = QueuedMockModel(["Pretty good, thanks!"])
        let orch = orchestrator(model)
        await orch.run(userMessage: "hey, how's it going")
        XCTAssertEqual(orch.messages.last { $0.role == .assistant }?.content, "Pretty good, thanks!")
    }
}
