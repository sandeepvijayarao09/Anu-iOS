import XCTest
@testable import Anu

/// Regressions from the first on-device run (2026-11-13): garbled text routed
/// to the agent as "math", and the agent prompt overflowing the 4,096-token
/// engine because it offered all 29 tools.
@MainActor
final class ToolSelectorTests: XCTestCase {
    private func orchestrator(_ replies: [String] = ["ok"]) -> AgentOrchestrator {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolsel-\(UUID().uuidString)", isDirectory: true)
        return AgentOrchestrator(model: QueuedMockModel(replies), sessionsDirectory: dir)
    }

    // MARK: Classifier

    func testGarbledTextIsNotMath() {
        for text in ["Wee ca fff", "Tv😒", "asdf qwer", "hmm"] {
            XCTAssertNotEqual(TaskClassifier.shared.classify(text).type, .math, text)
        }
    }

    func testRealMathStillLooksMathematical() {
        for text in ["15% of 80", "what is 12 times 7", "calculate the square root", "two plus two"] {
            XCTAssertTrue(TaskClassifier.looksMathematical(text), text)
        }
        XCTAssertFalse(TaskClassifier.looksMathematical("Wee ca fff"))
    }

    // MARK: Selection

    func testGarbledTurnGetsOnlyTheCoreTools() {
        let orch = orchestrator()
        let tools = ToolSelector.select(orch.toolRegistry.allTools, turns: ["Wee ca fff"], escalation: nil)
        XCTAssertEqual(Set(tools.map(\.name)), Set(ToolSelector.core))
    }

    func testATimerTurnGetsTheTimerTool() {
        let orch = orchestrator()
        let names = ToolSelector.select(orch.toolRegistry.allTools,
                                        turns: ["set a timer for 10 minutes"], escalation: nil).map(\.name)
        XCTAssertTrue(names.contains("set_timer"), "\(names)")
        XCTAssertTrue(names.contains("datetime"))
        XCTAssertFalse(names.contains("phone_share"), "\(names)")
    }

    func testOnlyTheActiveProvidersEscalationToolIsOffered() async {
        let orch = orchestrator()
        await orch.setup()   // registers the escalation tools
        let names = ToolSelector.select(orch.toolRegistry.allTools, turns: ["write an essay about the sea"],
                                        escalation: "escalate_to_gemini").map(\.name)
        XCTAssertTrue(names.contains("escalate_to_gemini"), "\(names)")
        XCTAssertFalse(names.contains("escalate_to_mac"))
        XCTAssertFalse(names.contains("escalate_to_private_cloud"))
        XCTAssertFalse(ToolSelector.select(orch.toolRegistry.allTools, turns: ["hi"], escalation: nil)
            .contains { $0.name.hasPrefix("escalate_to_") })
    }

    func testSelectedToolsStayWithinTheBudget() {
        let orch = orchestrator()
        let everything = "set a timer, remind me, check my calendar, call mom, flashlight, brightness, "
            + "directions to the airport, open maps, share this, search the news, photos, pdf, draw an image, "
            + "convert 5 km to miles, copy to clipboard, run my shortcut"
        let tools = ToolSelector.select(orch.toolRegistry.allTools, turns: [everything], escalation: "escalate_to_gemini")
        let cost = tools.reduce(0) { $0 + ToolSelector.cost($1) }
        XCTAssertLessThanOrEqual(cost, ToolSelector.budgetTokens)
        XCTAssertLessThan(tools.count, orch.toolRegistry.allTools.count)
    }

    func testTheAgentPromptNowFitsTheEngine() async {
        let orch = orchestrator()
        orch.conversationHistory = [.user("Wee ca fff")]
        let prompt = GemmaChatTemplate.format(messages: orch.conversationHistory,
                                              tools: orch.toolsForCurrentTurn, memoryContext: nil)
        // ~3.5 characters a token; the 4,096-token engine also needs room to answer.
        XCTAssertLessThan(Double(prompt.count) / 3.5, 2_500, "agent prompt is \(prompt.count) characters")
    }

    /// The owner's requirement: a message of up to 10 lines always fits, with
    /// room for the answer, on the agent path (the longest prompt).
    func testATenLineMessageFitsWithRoomToAnswer() {
        let orch = orchestrator()
        let line = "Please plan my Saturday: a run at 7, groceries, call mom, and set reminders for each one."
        let message = Array(repeating: line, count: 10).joined(separator: "\n")
        orch.conversationHistory = [.user(message)]
        let prompt = GemmaChatTemplate.format(messages: orch.conversationHistory,
                                              tools: orch.toolsForCurrentTurn, memoryContext: nil)
        let promptTokens = Int((Double(prompt.count) / 3.5).rounded(.up))
        let answerRoom = 1_024
        XCTAssertLessThan(promptTokens + answerRoom, 4_096,
                          "fits even the old 4,096 engine; prompt ≈ \(promptTokens) tokens")
        XCTAssertGreaterThanOrEqual(LiteRTLMModel.contextTokens, 8_192)
    }

    func testLoadingASkillBringsItsScriptTools() {
        let orch = orchestrator()
        let names = ToolSelector.select(orch.toolRegistry.allTools,
                                        turns: ["sha-256 hash of hello world"], escalation: nil).map(\.name)
        if names.contains("load_skill") {
            XCTAssertTrue(names.contains("run_js"), "\(names)")
        }
    }

    // MARK: Too-long retry

    func testATooLongPromptIsRetriedWithFewerToolsAndNeverShown() async {
        let tooLong = "\n[Generation error: Invalid response from native layer: INVALID_ARGUMENT: "
            + "Input token ids are too long. Exceeding the maximum number of tokens allowed: 4204 >= 4096]"
        let orch = orchestrator([tooLong, "Here's the answer."])
        orch.conversationHistory = [.user("set a timer for 10 minutes")]
        orch.currentRunState = RunState(turnKey: "t")
        await orch.reactLoop(startingIteration: 0)
        XCTAssertEqual(orch.conversationHistory.last?.content, "Here's the answer.")
        XCTAssertFalse(orch.messages.contains { $0.content.contains("Input token ids are too long") },
                       "the raw engine error is never shown")
        XCTAssertTrue(orch.reasoningSteps.contains { $0.action == "Tried again with fewer tools" })
        XCTAssertTrue(AgentOrchestrator.isPromptTooLong(tooLong))
        XCTAssertFalse(AgentOrchestrator.isPromptTooLong("A normal answer."))
    }

    func testEngineErrorsBecomePlainSentences() {
        XCTAssertNil(AgentOrchestrator.friendlyEngineError("Paris is the capital of France."))
        let long = AgentOrchestrator.friendlyEngineError("[Generation error: INVALID_ARGUMENT: Input token ids are too long.]")
        XCTAssertTrue(long?.hasPrefix("That was too long") == true)
        let vision = AgentOrchestrator.friendlyEngineError("[Generation error: Vision executor should not be null]")
        XCTAssertTrue(vision?.contains("picture") == true)
        XCTAssertNotNil(AgentOrchestrator.friendlyEngineError("\n[Generation error: something else]"))
    }

    func testEscalationToolsWaitLongerThanOthers() {
        XCTAssertEqual(EscalateToGeminiTool(geminiClient: GeminiClient(vault: Vault(backend: InMemoryVaultBackend()))).timeout,
                       ToolBroker.escalationTimeout)
        XCTAssertEqual(CalculatorTool().timeout, ToolBroker.toolTimeout)
    }
}
