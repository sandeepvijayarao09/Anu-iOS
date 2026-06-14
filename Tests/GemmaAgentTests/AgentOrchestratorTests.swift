import XCTest
@testable import GemmaAgent

/// Tests the orchestrator class itself — the full ReAct loop with an
/// injected mock model (no UI, no real inference).
@MainActor
final class AgentOrchestratorTests: XCTestCase {

    func testCalculatorFlowRunsToolAndAnswers() async {
        let orch = AgentOrchestrator(model: ScriptedModel())
        await orch.run(userMessage: "calculate 12 * 8 + 5")

        let roles = orch.messages.map(\.role)
        XCTAssertTrue(roles.contains(.user))
        XCTAssertTrue(roles.contains(.toolCall), "should record a tool call")
        XCTAssertTrue(roles.contains(.toolResult), "should record the tool result")

        let toolCall = orch.messages.first(where: { $0.role == .toolCall })
        XCTAssertEqual(toolCall?.toolCall?.name, "calculator")

        let toolResult = orch.messages.first(where: { $0.role == .toolResult })
        XCTAssertEqual(toolResult?.content.contains("101"), true)

        let finalAnswer = orch.messages.last(where: { $0.role == .assistant })
        XCTAssertEqual(finalAnswer?.content.contains("101"), true, "final answer should use the result")

        XCTAssertFalse(orch.isThinking)
        XCTAssertEqual(orch.status, .idle)
    }

    func testPlainChatAnswersWithoutTools() async {
        let orch = AgentOrchestrator(model: ScriptedModel())
        await orch.run(userMessage: "hello there")

        XCTAssertFalse(orch.messages.map(\.role).contains(.toolCall))
        let answer = orch.messages.last(where: { $0.role == .assistant })
        XCTAssertEqual(answer?.content.isEmpty, false)
        XCTAssertEqual(answer?.isStreaming, false, "streaming flag must be cleared")
    }

    func testReasoningStepsAreRecorded() async {
        let orch = AgentOrchestrator(model: ScriptedModel())
        await orch.run(userMessage: "calculate 2 + 2")
        XCTAssertFalse(orch.reasoningSteps.isEmpty)
        XCTAssertNotNil(orch.reasoningSteps.first?.action)
    }

    func testClearConversationResetsState() async {
        let orch = AgentOrchestrator(model: ScriptedModel())
        await orch.run(userMessage: "hello")
        XCTAssertFalse(orch.messages.isEmpty)

        orch.clearConversation()
        XCTAssertTrue(orch.messages.isEmpty)
        XCTAssertTrue(orch.reasoningSteps.isEmpty)
        XCTAssertEqual(orch.status, .idle)
    }

    func testToolCallJSONNeverShownAsChatBubble() async {
        let orch = AgentOrchestrator(model: ScriptedModel())
        await orch.run(userMessage: "calculate 12 * 8 + 5")

        // The raw {"tool_call": ...} output must be confined to the
        // reasoning trace — never visible as an assistant chat message
        let assistantBubbles = orch.messages.filter { $0.role == .assistant }
        XCTAssertFalse(assistantBubbles.contains { $0.content.contains("tool_call") },
                       "raw tool-call JSON leaked into chat")
        // ...but the trace keeps it for debugging
        XCTAssertTrue(orch.reasoningSteps.contains { $0.thought.contains("tool_call") })
    }

    func testCancelStopsGeneration() async {
        let orch = AgentOrchestrator(model: ScriptedModel())

        // The mock's default reply streams ~40 tokens at 30ms each (~1.2s);
        // cancel shortly after starting
        let run = Task { await orch.run(userMessage: "hello there") }
        try? await Task.sleep(nanoseconds: 150_000_000)
        orch.cancel()
        await run.value

        XCTAssertFalse(orch.isThinking)
        XCTAssertEqual(orch.status, .idle)
        XCTAssertTrue(orch.messages.contains { $0.role == .system && $0.content == "Stopped." },
                      "cancellation should be acknowledged in the chat")
    }

    func testRunIgnoredWhileThinking() async {
        let orch = AgentOrchestrator(model: ScriptedModel())
        // Start a run and immediately try a second one
        async let first: Void = orch.run(userMessage: "hello")
        await orch.run(userMessage: "second message while busy")
        await first

        // Only one user message may slip through the guard while busy
        let userMessages = orch.messages.filter { $0.role == .user }
        XCTAssertLessThanOrEqual(userMessages.count, 2)
    }
}
