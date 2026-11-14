import XCTest
@testable import Anu

/// A screenshot question (Android ADR-083's closest iOS form) is a photo turn:
/// it stays on the phone, and nothing that sends text off the phone may run
/// while it's in the model's view. Locks in the rule for every screenshot path,
/// which all land in the composer as photos.
@MainActor
final class ScreenTurnPrivacyTests: XCTestCase {
    private func screenshot() -> Data {
        // A small opaque PNG stands in for a screenshot.
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        return Data(base64Encoded: png)!
    }

    func testAScreenshotTurnStaysOnTheDeviceAndRefusesEscalation() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screen-\(UUID().uuidString)", isDirectory: true)
        let model = QueuedMockModel(["It's a settings screen."])
        let orch = AgentOrchestrator(model: model, sessionsDirectory: dir)

        await orch.run(userMessage: "What's on my screen?",
                       attachments: MessageAttachments(photos: [screenshot()]))

        let route = orch.reasoningSteps.first { $0.action?.hasPrefix("Route →") == true }
        XCTAssertEqual(route?.action, "Route → \(ModelRoute.onDeviceChat.displayName)")
        XCTAssertTrue(route?.thought.contains("photo/PDF in view (on-device only)") == true, route?.thought ?? "")
        XCTAssertFalse(model.capturedPrompts.isEmpty, "answered by the on-device model")

        XCTAssertTrue(orch.hasMediaInView)
        for name in ["escalate_to_gemini", "escalate_to_mac", "escalate_to_private_cloud"] {
            XCTAssertEqual(orch.mediaEgressRefusal(for: ToolCallInfo(name: name, arguments: .object([:]))),
                           AgentOrchestrator.mediaStaysOnPhone, name)
        }
        XCTAssertNil(orch.mediaEgressRefusal(for: ToolCallInfo(name: "calculator", arguments: .object([:]))),
                     "on-device tools still run")
    }
}
