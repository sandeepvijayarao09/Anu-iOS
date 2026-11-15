import XCTest
import os
@testable import Anu

/// Warm start and named waits (Android ADR-074).
@MainActor
final class WarmStartTests: XCTestCase {
    private final class Conditions: DeviceConditionsProviding {
        var value: DeviceConditions
        init(_ value: DeviceConditions) { self.value = value }
        func current() -> DeviceConditions { value }
    }

    /// A model whose activity the test sets, counting warm-ups.
    private final class BusyModel: LocalLanguageModel, @unchecked Sendable {
        let modelName = "Gemma 4 E4B (LiteRT-LM)"
        private let state = OSAllocatedUnfairLock(initialState: (activity: ModelActivity.idle, warmUps: 0))
        var current: ModelActivity {
            get { state.withLock { $0.activity } }
            set { state.withLock { $0.activity = newValue } }
        }
        var warmUps: Int { state.withLock { $0.warmUps } }
        func load() async throws {}
        func generate(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String> {
            AsyncStream { $0.yield("ok"); $0.finish() }
        }
        func activity() async -> ModelActivity { current }
        func warmUp() async { state.withLock { $0.warmUps += 1 } }
    }

    private func orchestrator(_ model: BusyModel, _ conditions: DeviceConditions = .normal) -> AgentOrchestrator {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("warm-\(UUID().uuidString)", isDirectory: true)
        let orch = AgentOrchestrator(model: model, sessionsDirectory: dir)
        orch.deviceConditions = Conditions(conditions)
        return orch
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, seconds: Double = 3) async {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func testAWaitIsNamedAfterASecondAndClearedWhenIdle() async {
        let model = BusyModel()
        model.current = .loading
        let orch = orchestrator(model)
        orch.isThinking = true
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(orch.waitNote, "not named before a second")
        await waitUntil(orch.waitNote != nil)
        XCTAssertEqual(orch.waitNote, "Getting Gemma 4 E4B ready…")
        model.current = .idle
        await waitUntil(orch.waitNote == nil)
        XCTAssertNil(orch.waitNote)
        orch.isThinking = false
    }

    func testReadingTheChatIsNamed() async {
        let model = BusyModel()
        model.current = .reading
        let orch = orchestrator(model)
        orch.isThinking = true
        await waitUntil(orch.waitNote != nil)
        XCTAssertEqual(orch.waitNote, "Catching up on this chat…")
        orch.isThinking = false
        XCTAssertNil(orch.waitNote, "a finished turn has no wait")
    }

    func testWaitNotes() {
        XCTAssertNil(ModelActivity.idle.waitNote(modelName: "x"))
        XCTAssertEqual(ModelActivity.settingUpGPU.waitNote(modelName: "x"),
                       "Setting up the GPU. First time only, about a minute.")
        XCTAssertEqual(ModelActivity.shortName("Gemma 4 E2B (LiteRT-LM)"), "Gemma 4 E2B")
        XCTAssertEqual(ModelActivity.shortName("Apple on-device"), "Apple on-device")
    }

    func testWarmUpLoadsTheModel() async {
        let model = BusyModel()
        let orch = orchestrator(model)
        orch.warmUp()
        await waitUntil(model.warmUps == 1)
        XCTAssertEqual(model.warmUps, 1)
    }

    func testNoWarmUpWhenThePhoneIsHotOrMidAnswer() async {
        let hot = BusyModel()
        orchestrator(hot, DeviceConditions(thermal: .serious, batteryLevel: nil, charging: true)).warmUp()
        let busy = BusyModel()
        let orch = orchestrator(busy)
        orch.isThinking = true
        orch.warmUp()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(hot.warmUps, 0, "a load can't be stopped, so not while the phone is hot")
        XCTAssertEqual(busy.warmUps, 0, "an answer is already using the model")
        orch.isThinking = false
    }
}
