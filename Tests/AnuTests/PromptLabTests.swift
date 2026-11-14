import XCTest
@testable import Anu

@MainActor
final class PromptLabTests: XCTestCase {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lab-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - The request carries nothing but the instruction and the prompt

    func testLabPromptHasOnlyInstructionAndPrompt() {
        XCTAssertEqual(PromptLab.prompt(instruction: "  Be brief. ", prompt: " Why is the sky blue? "),
                       "<start_of_turn>user\nBe brief.\n\nWhy is the sky blue?<end_of_turn>\n<start_of_turn>model\n")
        XCTAssertEqual(PromptLab.prompt(instruction: "", prompt: "Hi"),
                       "<start_of_turn>user\nHi<end_of_turn>\n<start_of_turn>model\n")
    }

    func testSideGenerationSkipsMemoryToolsHistoryAndChat() async throws {
        let model = MeteredMockModel(["Earlier answer.", "Rayleigh scattering."])
        let orch = AgentOrchestrator(model: model, sessionsDirectory: tempDir())
        await orch.run(userMessage: "hello")
        let chatMessages = orch.messages.count
        let history = orch.conversationHistory.count
        let resetsBefore = model.resets

        let request = PromptLab.prompt(instruction: "Be brief.", prompt: "Why is the sky blue?")
        var streamed = ""
        let result = try await orch.sideGeneration(prompt: request, config: LabSampling().config) { streamed += $0 }

        XCTAssertEqual(result.text, "Rayleigh scattering.")
        XCTAssertEqual(streamed, "Rayleigh scattering.")
        XCTAssertEqual(model.prompts.last, request, "exactly the lab request: no memory, tools or chat history")
        XCTAssertFalse(model.prompts.last?.contains("hello") ?? true)
        XCTAssertEqual(orch.messages.count, chatMessages, "nothing is saved into the chat")
        XCTAssertEqual(orch.conversationHistory.count, history)
        XCTAssertEqual(model.resets, resetsBefore, "it runs apart, so the chat's cached reading is kept")
        XCTAssertFalse(orch.isThinking)
    }

    func testSideGenerationWaitsForNoOneWhileChatIsBusy() async {
        let orch = AgentOrchestrator(model: MeteredMockModel(["x"]), sessionsDirectory: tempDir())
        orch.isThinking = true
        do {
            _ = try await orch.sideGeneration(prompt: "p", config: LabSampling().config)
            XCTFail("should refuse while the chat is answering")
        } catch {
            XCTAssertEqual(error as? SideGenerationError, .busy)
        }
    }

    func testSideGenerationCutsAtTheLongestAnswer() async throws {
        let long = Array(repeating: "word", count: 400).joined(separator: " ")
        let orch = AgentOrchestrator(model: MeteredMockModel([long]), sessionsDirectory: tempDir())
        var config = LabSampling().config
        config.maxNewTokens = 64
        let result = try await orch.sideGeneration(prompt: "p", config: config)
        XCTAssertTrue(result.cut)
        XCTAssertLessThan(result.text.count, long.count)
    }

    func testSamplingAndThinkingReachTheModel() async throws {
        let model = MeteredMockModel(["ok"])
        let orch = AgentOrchestrator(model: model, sessionsDirectory: tempDir())
        let sampling = LabSampling(temperature: 0.2, topK: 7, topP: 0.5, maxTokens: 128, thinking: true)
        _ = try await orch.sideGeneration(prompt: "p", config: sampling.config)
        let config = try XCTUnwrap(model.configs.last)
        XCTAssertEqual(config.temperature, 0.2, accuracy: 1e-6)
        XCTAssertEqual(config.topK, 7)
        XCTAssertEqual(config.topP, 0.5, accuracy: 1e-6)
        XCTAssertEqual(config.maxNewTokens, 128)
        XCTAssertTrue(config.thinking)
    }

    // MARK: - Templates

    func testTemplatesWriteAnEditableInstruction() {
        let lab = PromptLabModel { _, _, _ in throw SideGenerationError.busy }
        XCTAssertEqual(lab.instruction, "")
        lab.choose(.rewrite)
        XCTAssertEqual(lab.option, "Formal")
        XCTAssertTrue(lab.instruction.hasPrefix("Rewrite the user's text to be formal."))
        lab.choose(option: "Shorter")
        XCTAssertTrue(lab.instruction.contains("to be shorter"))
        lab.choose(.summarize)
        lab.choose(option: "One line")
        XCTAssertEqual(lab.instruction, "Summarize the user's text in one sentence. Reply with the sentence only.")
        lab.choose(.code)
        XCTAssertTrue(lab.instruction.hasPrefix("Write Swift code"))
        lab.instruction = "My own instruction"
        XCTAssertEqual(lab.instruction, "My own instruction")
        lab.choose(.freeForm)
        XCTAssertEqual(lab.instruction, "")
        XCTAssertNil(lab.option)
    }

    func testGreedySampling() {
        let lab = PromptLabModel { _, _, _ in throw SideGenerationError.busy }
        lab.useGreedy()
        XCTAssertEqual(lab.sampling.temperature, 0)
        XCTAssertEqual(lab.sampling.topK, 1)
        XCTAssertEqual(lab.sampling.topP, 1)
        XCTAssertFalse(lab.canRun, "nothing to run without a prompt")
    }

    // MARK: - Running

    func testRunShowsAnswerReasoningAndSpeed() async {
        var sent: (String, GenerationConfig)?
        let lab = PromptLabModel { prompt, config, onToken in
            sent = (prompt, config)
            onToken("Hel")
            onToken("lo")
            return SideGenerationResult(text: "Hello", thought: "Say hello.", tokensIn: 40, tokensOut: 20,
                                        counted: true, firstWordMs: 800, readMs: 400, writeMs: 1000,
                                        thoughtMs: 600, stopped: false)
        }
        lab.choose(.summarize)
        lab.prompt = "A long text."
        lab.sampling.thinking = true
        lab.run()
        await lab.waitForRun()

        XCTAssertEqual(lab.output, "Hello")
        XCTAssertEqual(lab.reasoning, "Say hello.")
        XCTAssertEqual(lab.speed, "thought 0.6 s · first word 0.8 s · read 100 tokens/s · wrote 20 tokens/s")
        XCTAssertFalse(lab.running)
        XCTAssertNil(lab.error)
        XCTAssertTrue(sent?.0.contains("Summarize the user's text") ?? false)
        XCTAssertTrue(sent?.0.contains("A long text.") ?? false)
        XCTAssertEqual(sent?.1.thinking, true)
    }

    func testStopKeepsWhatWasWritten() async {
        let lab = PromptLabModel { _, _, onToken in
            onToken("Partial")
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return SideGenerationResult(text: "never", thought: nil, tokensIn: 0, tokensOut: 0, counted: false,
                                        firstWordMs: nil, readMs: 0, writeMs: 0, thoughtMs: nil, stopped: false)
        }
        lab.prompt = "Go"
        lab.run()
        try? await Task.sleep(nanoseconds: 50_000_000)
        lab.stop()
        await lab.waitForRun()
        XCTAssertEqual(lab.output, "Partial")
        XCTAssertTrue(lab.stopped)
        XCTAssertFalse(lab.running)
    }

    func testFailureIsShown() async {
        let lab = PromptLabModel { _, _, _ in throw SideGenerationError.failed("Model unavailable") }
        lab.prompt = "Go"
        lab.run()
        await lab.waitForRun()
        XCTAssertEqual(lab.error, "Model unavailable")
        XCTAssertFalse(lab.running)
    }
}
