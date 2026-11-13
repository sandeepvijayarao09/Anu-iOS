import XCTest
import os
@testable import Anu

/// Records each generation's token budget, so a test can see the guard's cap.
private final class BudgetRecordingModel: LocalLanguageModel, Sendable {
    nonisolated let modelName = "Budget Recorder"
    private let budgets = OSAllocatedUnfairLock(initialState: [Int]())
    var recorded: [Int] { budgets.withLock { $0 } }
    func load() async throws {}
    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String> {
        budgets.withLock { $0.append(config.maxNewTokens) }
        return AsyncStream { continuation in
            continuation.yield("Hi there!")
            continuation.finish()
        }
    }
}

@MainActor
private final class FakeConditions: DeviceConditionsProviding {
    var value: DeviceConditions
    init(_ value: DeviceConditions) { self.value = value }
    func current() -> DeviceConditions { value }
}

/// The Direct tier in the orchestrator (Android parity #17): a whole phone
/// command runs through the broker with no model and a "no model needed"
/// label; anything else reaches the router. Plus the guard's effect on a
/// model turn (#23).
@MainActor
final class DirectTierTests: XCTestCase {
    private var asked: [ApprovalRequest] = []

    private func makeOrch(_ model: any LocalLanguageModel) -> AgentOrchestrator {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("direct-\(UUID().uuidString)", isDirectory: true)
        let orch = AgentOrchestrator(model: model, sessionsDirectory: dir)
        orch.approvals.autoDecide = { [unowned self] request in
            self.asked.append(request)
            return .denied
        }
        orch.deviceConditions = FakeConditions(.normal)
        return orch
    }

    func testTimerRunsWithNoModel() async {
        let model = QueuedMockModel([])
        let orch = makeOrch(model)
        let scheduler = PhoneFakeScheduler()
        orch.toolRegistry.register(TimerTool(scheduler: scheduler))

        await orch.run(userMessage: "Set a timer for 10 minutes")

        XCTAssertTrue(model.capturedPrompts.isEmpty, "no model call")
        XCTAssertTrue(asked.isEmpty, "a clean private change doesn't ask")
        XCTAssertEqual(scheduler.scheduled.first?.kind, .timer)
        let answer = orch.messages.last { $0.role == .assistant }
        XCTAssertEqual(answer?.label, AgentOrchestrator.directLabel)
        XCTAssertEqual(answer?.content.hasPrefix("Set timer"), true, answer?.content ?? "")
        XCTAssertEqual(answer?.receipts?.map(\.status), [.done])
        XCTAssertEqual(orch.messages.first { $0.role == .toolCall }?.toolCall?.name, "set_timer")
        XCTAssertFalse(orch.isThinking)
        XCTAssertEqual(orch.status, .idle)
    }

    func testFlashlightRunsWithNoModel() async {
        let model = QueuedMockModel([])
        let orch = makeOrch(model)
        let torch = PhoneFakeTorch()
        orch.toolRegistry.register(FlashlightTool(torch: torch))

        await orch.run(userMessage: "flashlight on")

        XCTAssertTrue(model.capturedPrompts.isEmpty)
        XCTAssertEqual(torch.calls.map(\.on), [true])
        XCTAssertEqual(orch.messages.last?.content, "Flashlight on.")
        XCTAssertEqual(orch.messages.last?.label, AgentOrchestrator.directLabel)
    }

    func testDestructiveCommandStillAsksAndADeclineDoesNothing() async {
        let model = QueuedMockModel([])
        let orch = makeOrch(model)

        await orch.run(userMessage: "cancel my reminder to call Mom")

        XCTAssertTrue(model.capturedPrompts.isEmpty)
        XCTAssertEqual(asked.map(\.risk), [.destructive])
        XCTAssertEqual(asked.first?.summary, "Delete the reminder “call Mom”")
        let answer = orch.messages.last { $0.role == .assistant }
        XCTAssertEqual(answer?.content, "Okay, I didn't do that.")
        XCTAssertEqual(answer?.receipts?.map(\.status), [.declined])
    }

    func testVolumeAnswersHonestlyWithNoTool() async {
        let model = QueuedMockModel([])
        let orch = makeOrch(model)

        await orch.run(userMessage: "set the volume to 50%")

        XCTAssertTrue(model.capturedPrompts.isEmpty)
        XCTAssertFalse(orch.messages.contains { $0.role == .toolCall })
        XCTAssertEqual(orch.messages.last?.content, PhoneCommands.volumeAnswer)
        XCTAssertEqual(orch.messages.last?.label, AgentOrchestrator.directLabel)
    }

    func testNearMissGoesToTheModel() async {
        let model = QueuedMockModel(["Sure."])
        let orch = makeOrch(model)
        orch.toolRegistry.register(TimerTool(scheduler: PhoneFakeScheduler()))

        await orch.run(userMessage: "set a timer for 10 minutes and email Maya the agenda")

        XCTAssertFalse(model.capturedPrompts.isEmpty, "more than one command is the model's")
        XCTAssertFalse(orch.messages.contains { $0.label == AgentOrchestrator.directLabel })
    }

    func testCommandForAToolThatIsNotHereGoesToTheModel() async {
        // App-launch tools arrive with the connectors, which tests don't load.
        let model = QueuedMockModel(["Opening it."])
        let orch = makeOrch(model)
        XCTAssertNil(orch.toolRegistry.tool(named: "phone_open_app"))

        await orch.run(userMessage: "open Spotify")

        XCTAssertFalse(model.capturedPrompts.isEmpty)
    }

    func testScriptedModelChatStillWorksAfterTheDirectStep() async {
        let orch = makeOrch(ScriptedModel())
        await orch.run(userMessage: "hello there")
        let answer = orch.messages.last { $0.role == .assistant }
        XCTAssertEqual(answer?.content.isEmpty, false)
        XCTAssertNil(answer?.label)
    }

    // MARK: Guard

    func testGuardCapsOnDeviceAnswersWhileWarm() async {
        let model = BudgetRecordingModel()
        let orch = makeOrch(model)
        orch.deviceConditions = FakeConditions(DeviceConditions(thermal: .serious, batteryLevel: 0.8, charging: false))

        await orch.run(userMessage: "calculate 12 * 8 + 5")

        XCTAssertEqual(model.recorded, [min(DeviceGuard.answerTokens, GenerationConfig.agentFromSettings.maxNewTokens)])
        XCTAssertTrue(orch.reasoningSteps.contains { $0.thought == DeviceGuard.heat.note })
    }

    func testNoGuardKeepsTheUsualBudget() async {
        let model = BudgetRecordingModel()
        let orch = makeOrch(model)

        await orch.run(userMessage: "calculate 12 * 8 + 5")

        XCTAssertEqual(model.recorded, [GenerationConfig.agentFromSettings.maxNewTokens])
        XCTAssertFalse(orch.reasoningSteps.contains { $0.action?.hasPrefix("Guard") == true })
    }

    func testLowBatteryGuardsTheTurn() async {
        let model = BudgetRecordingModel()
        let orch = makeOrch(model)
        orch.deviceConditions = FakeConditions(DeviceConditions(thermal: .nominal, batteryLevel: 0.1, charging: false))

        await orch.run(userMessage: "calculate 12 * 8 + 5")

        XCTAssertEqual(model.recorded, [min(DeviceGuard.answerTokens, GenerationConfig.agentFromSettings.maxNewTokens)])
        XCTAssertTrue(orch.reasoningSteps.contains { $0.thought == DeviceGuard.battery.note })
    }

    func testDirectAnswerWording() {
        XCTAssertEqual(AgentOrchestrator.directAnswer(for: .ok(result: "Flashlight on.", summary: "", wrote: true)),
                       "Flashlight on.")
        XCTAssertEqual(AgentOrchestrator.directAnswer(for: .rejected(
            reason: "Blocked: opening apps & running Shortcuts is turned off. Enable it in Settings → Connectors.",
            summary: "", code: .notAllowed)),
            "opening apps & running Shortcuts is turned off. Enable it in Settings → Connectors.")
        XCTAssertEqual(AgentOrchestrator.directAnswer(for: .failed(
            reason: "Tool execution failed: This device has no flashlight.", summary: "")),
            "I couldn't do that: This device has no flashlight.")
    }
}
