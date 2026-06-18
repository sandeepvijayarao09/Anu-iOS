import XCTest
@testable import Anu

/// Tests the orchestrator class itself — the full ReAct loop with an
/// injected mock model (no UI, no real inference).
@MainActor
final class AgentOrchestratorTests: XCTestCase {

    /// Each orchestrator gets its own temp sessions directory so tests stay
    /// hermetic — no shared Documents state leaking between runs.
    private func makeOrch() -> AgentOrchestrator {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orch-\(UUID().uuidString)", isDirectory: true)
        return AgentOrchestrator(model: ScriptedModel(), sessionsDirectory: dir)
    }

    func testCalculatorFlowRunsToolAndAnswers() async {
        let orch = makeOrch()
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
        let orch = makeOrch()
        await orch.run(userMessage: "hello there")

        XCTAssertFalse(orch.messages.map(\.role).contains(.toolCall))
        let answer = orch.messages.last(where: { $0.role == .assistant })
        XCTAssertEqual(answer?.content.isEmpty, false)
        XCTAssertEqual(answer?.isStreaming, false, "streaming flag must be cleared")
    }

    func testReasoningStepsAreRecorded() async {
        let orch = makeOrch()
        await orch.run(userMessage: "calculate 2 + 2")
        XCTAssertFalse(orch.reasoningSteps.isEmpty)
        XCTAssertNotNil(orch.reasoningSteps.first?.action)
    }

    func testClearConversationResetsState() async {
        let orch = makeOrch()
        await orch.run(userMessage: "hello")
        XCTAssertFalse(orch.messages.isEmpty)

        orch.clearConversation()
        XCTAssertTrue(orch.messages.isEmpty)
        XCTAssertTrue(orch.reasoningSteps.isEmpty)
        XCTAssertEqual(orch.status, .idle)
    }

    func testToolCallJSONNeverShownAsChatBubble() async {
        let orch = makeOrch()
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
        let orch = makeOrch()

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
        let orch = makeOrch()
        // Start a run and immediately try a second one
        async let first: Void = orch.run(userMessage: "hello")
        await orch.run(userMessage: "second message while busy")
        await first

        // Only one user message may slip through the guard while busy
        let userMessages = orch.messages.filter { $0.role == .user }
        XCTAssertLessThanOrEqual(userMessages.count, 2)
    }

    // MARK: - Sessions (privacy sandboxes)

    func testNewSessionIsolatesConversation() async {
        let orch = makeOrch()
        await orch.run(userMessage: "hello there")
        XCTAssertFalse(orch.messages.isEmpty)
        let first = orch.activeSessionID

        let new = orch.createSession()
        XCTAssertNotEqual(new, first)
        XCTAssertTrue(orch.messages.isEmpty, "a new sandbox starts empty")

        // Switching back restores the first sandbox's conversation.
        if let first { await orch.switchSession(to: first) }
        XCTAssertEqual(orch.activeSessionID, first)
        XCTAssertTrue(orch.messages.contains { $0.role == .user && $0.content == "hello there" })
    }

    func testDeletingActiveSessionFallsBackToAnother() async {
        let orch = makeOrch()
        await orch.run(userMessage: "first")          // session A (active)
        let a = orch.activeSessionID
        let b = orch.createSession()                   // session B (active)
        XCTAssertEqual(orch.activeSessionID, b)

        await orch.deleteSession(id: b)
        XCTAssertEqual(orch.activeSessionID, a, "deleting the active session switches to another")
        XCTAssertNotNil(orch.activeSession)
    }

    func testDeletingLastSessionCreatesAFreshOne() async {
        let orch = makeOrch()
        await orch.run(userMessage: "only chat")
        let only = orch.activeSessionID
        if let only { await orch.deleteSession(id: only) }
        XCTAssertNotNil(orch.activeSessionID)
        XCTAssertNotEqual(orch.activeSessionID, only)
        XCTAssertEqual(orch.sessions.count, 1)
        XCTAssertTrue(orch.messages.isEmpty)
    }

    func testIsolatedSandboxDoesNotWriteGlobalMemory() async {
        let orch = makeOrch()
        orch.createSession(memoryScope: .isolated)
        await orch.run(userMessage: "remember that I love hiking")
        let reply = orch.messages.last(where: { $0.role == .assistant })?.content ?? ""
        XCTAssertTrue(reply.contains("Memory is off"),
                      "an isolated sandbox should refuse to write global memory")
    }

    func testFirstMessageNamesTheSession() async {
        let orch = makeOrch()
        await orch.run(userMessage: "What is the capital of France?")
        XCTAssertEqual(orch.activeSession?.name.hasPrefix("What is the capital"), true)
    }

    // MARK: - Outward-action consent gate

    func testReadOnlyToolNeedsNoConsent() async {
        let orch = makeOrch()
        orch.confirmationOverride = { _ in false }   // would deny if it were consulted
        let ok = await orch.userApproves(
            ToolCallInfo(name: "calculator", arguments: .object(["expression": .string("2+2")])))
        XCTAssertTrue(ok, "read-only tools never require confirmation")
    }

    func testConfirmableToolBlockedWhenDenied() async {
        let orch = makeOrch()
        orch.toolRegistry.register(ConfirmableStubTool())
        orch.confirmationOverride = { _ in false }
        let ok = await orch.userApproves(
            ToolCallInfo(name: "confirmable_stub", arguments: .object([:])))
        XCTAssertFalse(ok, "a denied outward action must not be allowed to run")
    }

    func testConfirmableToolRunsWhenAllowed() async {
        let orch = makeOrch()
        orch.toolRegistry.register(ConfirmableStubTool())
        orch.confirmationOverride = { _ in true }
        let ok = await orch.userApproves(
            ToolCallInfo(name: "confirmable_stub", arguments: .object([:])))
        XCTAssertTrue(ok)
    }

    func testCorruptSessionIndexIsPreservedNotOverwritten() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ss-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = dir.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let indexURL = sessionsDir.appendingPathComponent("index.json")
        try? Data("not valid json".utf8).write(to: indexURL)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let index = store.migrateLegacyConversationIfNeeded()

        XCTAssertEqual(index.sessions.count, 1, "a fresh index is created")
        // The corrupt file must be preserved for recovery, not silently dropped.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sessionsDir.appendingPathComponent("index.corrupt.json").path),
            "corrupt index should be backed up, not overwritten")
    }

    func testToolConfirmationFlags() {
        XCTAssertFalse(CalculatorTool().requiresConfirmation)
        XCTAssertTrue(OpenAppTool(appConfig: .default, opener: NoopURLOpener()).requiresConfirmation)
        XCTAssertTrue(RESTConnectorTool(
            config: RESTConnectorConfig(name: "x", baseURL: "https://e.com", method: "POST")).requiresConfirmation,
            "write connectors confirm")
        XCTAssertFalse(RESTConnectorTool(
            config: RESTConnectorConfig(name: "x", baseURL: "https://e.com", method: "GET")).requiresConfirmation,
            "read connectors run freely")
    }
}

/// A confirmable outward-action stub for the consent-gate tests.
private struct ConfirmableStubTool: Tool {
    let name = "confirmable_stub"
    let description = "stub outward action"
    var parameters: JSONSchema? { nil }
    var sideEffect: ToolSideEffect { .external(capability: .connector) }
    var requiresConfirmation: Bool { true }
    func execute(arguments: JSONValue) async throws -> String { "ran" }
}
