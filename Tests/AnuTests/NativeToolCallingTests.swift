import XCTest
import os
@testable import Anu

/// A model with its own tool loop, scripted: each step either proposes a tool
/// call (and reads back what Anu returns) or writes the answer.
final class FakeNativeModel: NativeToolCallingModel, @unchecked Sendable {
    enum Step { case call(String, JSONValue), say(String) }

    let modelName = "Fake Apple"
    let nativeToolBudgetTokens: Int
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var scripts: [[Step]] = []
        var observations: [String] = []
        var offered: [[String]] = []
        var turns: [NativeTurn] = []
    }

    init(budget: Int = 900, scripts: [[Step]]) {
        nativeToolBudgetTokens = budget
        lock.withLock { $0.scripts = scripts }
    }

    var observations: [String] { lock.withLock { $0.observations } }
    var offered: [[String]] { lock.withLock { $0.offered } }
    var turns: [NativeTurn] { lock.withLock { $0.turns } }

    func load() async throws {}

    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String> {
        AsyncStream { $0.yield("plain"); $0.finish() }
    }

    func respondNatively(_ turn: NativeTurn, tools: [any Tool], config: GenerationConfig,
                         onToolCall: @escaping @Sendable (ToolCallInfo) async -> String) async throws -> AsyncStream<String> {
        let script = lock.withLock { state -> [Step] in
            state.offered.append(tools.map(\.name))
            state.turns.append(turn)
            return state.scripts.isEmpty ? [.say("done")] : state.scripts.removeFirst()
        }
        var text = ""
        for step in script {
            switch step {
            case .call(let name, let arguments):
                let observation = await onToolCall(ToolCallInfo(name: name, arguments: arguments))
                lock.withLock { $0.observations.append(observation) }
            case .say(let words):
                text += words
            }
        }
        let answer = text
        return AsyncStream { $0.yield(answer); $0.finish() }
    }
}

/// Parity A2: native tool calls on the Apple tiers still go through ToolBroker,
/// and the offered tools come from ToolSelector within Apple's small budget.
@MainActor
final class NativeToolCallingTests: XCTestCase {
    private func orchestrator(_ model: FakeNativeModel, message: String) -> AgentOrchestrator {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-\(UUID().uuidString)", isDirectory: true)
        let orch = AgentOrchestrator(model: model, sessionsDirectory: dir)
        orch.conversationHistory = [.user(message)]
        orch.currentRunState = RunState(turnKey: UUID().uuidString)
        return orch
    }

    func testAToolCallRunsThroughTheBrokerAndTheModelReadsTheResult() async {
        let model = FakeNativeModel(scripts: [[
            .call("calculator", .object(["expression": .string("6*7")])),
            .say("It's 42."),
        ]])
        let orch = orchestrator(model, message: "What is 6 times 7?")
        await orch.reactLoop(startingIteration: 0)

        XCTAssertEqual(model.observations.count, 1)
        XCTAssertTrue(model.observations[0].contains("42"), model.observations[0])
        XCTAssertTrue(orch.messages.contains { $0.role == .toolCall && $0.toolCall?.name == "calculator" })
        XCTAssertTrue(orch.messages.contains { $0.role == .toolResult && $0.content.contains("42") })
        XCTAssertEqual(orch.conversationHistory.last?.role, .assistant)
        XCTAssertEqual(orch.conversationHistory.last?.content, "It's 42.")
        XCTAssertEqual(orch.currentRunState?.toolCalls, 1, "the broker counted the call")
    }

    func testTheSystemDecidesAnUnknownToolIsRefused() async {
        let model = FakeNativeModel(scripts: [[.call("format_disk", .object([:])), .say("Sorry.")]])
        let orch = orchestrator(model, message: "Wipe everything")
        await orch.reactLoop(startingIteration: 0)
        XCTAssertTrue(model.observations[0].contains("There is no tool named format_disk"), model.observations[0])
    }

    func testADestructiveCallWaitsForApprovalAndADeclineIsReported() async {
        let model = FakeNativeModel(scripts: [[
            .call("reminders", .object(["action": .string("cancel"), "title": .string("Buy milk")])),
            .say("I didn't cancel it."),
        ]])
        let orch = orchestrator(model, message: "Cancel my buy milk reminder")
        let decline = Task { @MainActor in
            for _ in 0..<500 {
                if let pending = orch.approvals.pending {
                    orch.approvals.decide(pending.id, .denied)
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }
        await orch.reactLoop(startingIteration: 0)
        let asked = await decline.value
        XCTAssertTrue(asked, "the broker asked before a destructive call")
        XCTAssertTrue(model.observations[0].contains("declined"), model.observations[0])
        XCTAssertEqual(orch.currentRunState?.receipts.first?.status, .declined)
    }

    func testOfferedToolsComeFromToolSelectorWithinAppleBudget() async {
        let model = FakeNativeModel(budget: 400, scripts: [[.say("Sure.")]])
        let orch = orchestrator(model, message: "Remind me to call mom and set a timer for 10 minutes")
        await orch.reactLoop(startingIteration: 0)

        let offered = model.offered.first ?? []
        XCTAssertTrue(offered.contains("datetime") && offered.contains("calculator"), "\(offered)")
        let cost = orch.toolRegistry.allTools.filter { offered.contains($0.name) }.reduce(0) { $0 + ToolSelector.cost($1) }
        let core = ToolSelector.core.compactMap { orch.toolRegistry.tool(named: $0) }.reduce(0) { $0 + ToolSelector.cost($1) }
        XCTAssertLessThanOrEqual(cost, max(400, core), "\(offered)")
        XCTAssertLessThan(offered.count, orch.toolRegistry.allTools.count)
    }

    func testATooLongPromptRetriesWithTheCoreTools() async {
        let model = FakeNativeModel(scripts: [
            [.say("[Generation error: Exceeding the maximum number of tokens (Apple on-device)]")],
            [.say("Fine.")],
        ])
        let orch = orchestrator(model, message: "Set a timer and add a reminder and check my calendar")
        await orch.reactLoop(startingIteration: 0)
        XCTAssertEqual(model.offered.count, 2)
        XCTAssertEqual(Set(model.offered[1]), Set(model.offered[0]).intersection(ToolSelector.core))
        XCTAssertLessThan(model.offered[1].count, model.offered[0].count)
        XCTAssertEqual(orch.conversationHistory.last?.content, "Fine.")
    }

    func testAnUnbackedClaimIsMarkedAsNotDone() async {
        let model = FakeNativeModel(scripts: [[.say("I've sent the text to Maya.")]])
        let orch = orchestrator(model, message: "Text Maya that I'm on my way")
        await orch.reactLoop(startingIteration: 0)
        XCTAssertTrue(orch.conversationHistory.last?.content.contains(ActionClaims.notDoneWarning) ?? false)
    }

    func testInstructionsCarryMemoryAndNoJSONProtocol() async {
        let model = FakeNativeModel(scripts: [[.say("Hi!")]])
        let orch = orchestrator(model, message: "Hello")
        await orch.reactLoop(startingIteration: 0, memoryContext: "[M1] Likes tea")
        let turn = model.turns.first
        XCTAssertEqual(turn?.prompt, "Hello")
        XCTAssertTrue(turn?.instructions.contains("[M1] Likes tea") ?? false)
        XCTAssertFalse(turn?.instructions.contains("tool_call") ?? true)
    }

    // MARK: NativeTurn

    func testNativeTurnAlternatesAndFoldsToolTraffic() {
        let call = ToolCallInfo(name: "calculator", arguments: .object(["expression": .string("2+2")]))
        let window: [AgentMessage] = [
            .user("hi"), .assistant("hello"), .user("what's 2+2"),
            .toolCall(call), .toolResult(content: "4", forCallId: call.id),
            .assistant("4"), .user("and times 3?"),
        ]
        let turn = NativeTurn.build(window: window, instructions: "rules")
        XCTAssertEqual(turn.prompt, "and times 3?")
        XCTAssertEqual(turn.history.map(\.role), [.user, .assistant, .user, .assistant, .user, .assistant])
        XCTAssertTrue(turn.history[3].text.contains("calculator"))
        XCTAssertEqual(turn.history[4].text, "Tool result:\n4")
    }

    func testNativeTurnFromAGemmaPrompt() {
        let prompt = GemmaChatTemplate.formatChat(messages: [.user("Hi"), .assistant("Hey!"), .user("How are you?")])
        let turn = NativeTurn.fromGemmaPrompt(prompt)
        XCTAssertEqual(turn.prompt, "How are you?")
        XCTAssertEqual(turn.history.count, 2)
        XCTAssertTrue(turn.history[0].text.hasSuffix("Hi"))
        XCTAssertEqual(turn.history[1], NativeTurn.Entry(role: .assistant, text: "Hey!"))
    }

    // MARK: Fallback when nothing local can run

    func testNoLocalModelIsDetected() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nolocal-\(UUID().uuidString)")
        XCTAssertTrue(AgentOrchestrator(model: UnavailableModel(), sessionsDirectory: dir).noLocalModel)
        XCTAssertFalse(AgentOrchestrator(model: FakeNativeModel(scripts: []), sessionsDirectory: dir).noLocalModel)
    }
}
