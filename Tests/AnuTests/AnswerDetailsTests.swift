import XCTest
import os
@testable import Anu

/// A test model that reports usage the way LiteRT-LM does: counted tokens,
/// timings, and reasoning from the thought channel. Captures prompts and
/// configs. `charsPerToken` makes `countTokens` answer (for calibration).
final class MeteredMockModel: LocalLanguageModel, Sendable {
    nonisolated let modelName = "Metered Mock"
    nonisolated let supportsThinking = true

    private struct State {
        var responses: [String]
        var usage: GenerationUsage?
        var charsPerToken: Double?
        var prompts: [String] = []
        var configs: [GenerationConfig] = []
        var resets = 0
    }
    private let state: OSAllocatedUnfairLock<State>

    init(_ responses: [String], usage: GenerationUsage? = nil, charsPerToken: Double? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(responses: responses, usage: usage, charsPerToken: charsPerToken))
    }

    var prompts: [String] { state.withLock { $0.prompts } }
    var configs: [GenerationConfig] { state.withLock { $0.configs } }
    var resets: Int { state.withLock { $0.resets } }

    func load() async throws {}

    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String> {
        let next = state.withLock { s -> String in
            s.prompts.append(prompt)
            s.configs.append(config)
            return s.responses.isEmpty ? "Mock fallback answer" : s.responses.removeFirst()
        }
        let words = next.split(separator: Character(" "), omittingEmptySubsequences: false)
        return AsyncStream { continuation in
            for (i, word) in words.enumerated() { continuation.yield(i == 0 ? String(word) : " " + word) }
            continuation.finish()
        }
    }

    func lastUsage() async -> GenerationUsage? { state.withLock { $0.usage } }

    func countTokens(_ text: String) async -> Int? {
        state.withLock { $0.charsPerToken }.map { Int((Double(text.count) / $0).rounded()) }
    }

    func resetSession() async { state.withLock { $0.resets += 1 } }
}

@MainActor
final class AnswerDetailsTests: XCTestCase {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("details-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - Saved with each answer

    func testChatAnswerSavesOnDeviceDetails() async {
        let orch = AgentOrchestrator(model: ScriptedModel(), sessionsDirectory: tempDir())
        await orch.run(userMessage: "hello there")

        let answer = orch.messages.last(where: { $0.role == .assistant })
        let details = try? XCTUnwrap(answer?.details)
        XCTAssertEqual(details?.tier, .onDevice)
        XCTAssertEqual(details?.modelName, "Scripted Test Model")
        XCTAssertEqual(details?.route, "Chat")
        XCTAssertEqual(details?.counted, false, "the scripted model reports no counts, so these are estimates")
        XCTAssertGreaterThan(details?.tokensIn ?? 0, 0)
        XCTAssertGreaterThan(details?.tokensOut ?? 0, 0)
        XCTAssertNotNil(details?.firstWordMs)
        XCTAssertNotNil(details?.totalMs)
        XCTAssertEqual(details?.destinations, [])
        XCTAssertEqual(details.map(AnswerDetailsText.whereItWent), "Nothing left your device")
        XCTAssertNil(answer?.reasoning)
    }

    func testToolTurnListsToolsAndAgentRoute() async {
        let orch = AgentOrchestrator(model: ScriptedModel(), sessionsDirectory: tempDir())
        await orch.run(userMessage: "calculate 12 * 8 + 5 for my budget")

        let details = orch.messages.last(where: { $0.role == .assistant })?.details
        XCTAssertEqual(details?.toolsUsed, ["calculator"])
        XCTAssertEqual(details?.route, "Agent")
        // Two model steps (the tool call, then the answer) are both counted.
        XCTAssertGreaterThan(details?.tokensIn ?? 0, 0)
    }

    func testCountedUsageAndReasoningComeFromTheBackend() async {
        let usage = GenerationUsage(promptTokens: 120, outputTokens: 30, counted: true, backend: "GPU",
                                    thought: "The user greets me; reply warmly.", thoughtMs: 900,
                                    firstOutputMs: 400, decodeMs: 1500)
        let model = MeteredMockModel(["Hi! Nice to see you."], usage: usage)
        let orch = AgentOrchestrator(model: model, sessionsDirectory: tempDir())
        await orch.run(userMessage: "hello")

        let answer = orch.messages.last(where: { $0.role == .assistant })
        let details = answer?.details
        XCTAssertEqual(details?.counted, true)
        XCTAssertEqual(details?.tokensIn, 120)
        XCTAssertEqual(details?.tokensOut, 30)
        XCTAssertEqual(details?.backend, "GPU")
        XCTAssertEqual(details?.thoughtMs, 900)
        XCTAssertEqual(details?.writeRate ?? 0, 20, accuracy: 0.01, "30 tokens in 1.5 s")
        XCTAssertEqual(details?.readRate ?? 0, 300, accuracy: 0.01, "120 tokens in 0.4 s")
        // The reasoning is kept apart from the answer, and never reaches the model again.
        XCTAssertEqual(answer?.reasoning, "The user greets me; reply warmly.")
        XCTAssertEqual(answer?.content, "Hi! Nice to see you.")
        XCTAssertFalse(orch.conversationHistory.contains { $0.content.contains("greets me") })
        // With Show Reasoning on, the trace shows it too.
        XCTAssertTrue(orch.reasoningSteps.contains { $0.kind == .thought && $0.thought.contains("greets me") })
        XCTAssertEqual(details.map(AnswerDetailsText.whoAnswered), "Metered Mock · GPU, on this device")
    }

    func testThinkingSettingReachesTheModel() async {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: ThinkingSetting.key)
        defer { defaults.removeObject(forKey: ThinkingSetting.key) }

        let model = MeteredMockModel(["Fine."])
        let orch = AgentOrchestrator(model: model, sessionsDirectory: tempDir())
        await orch.run(userMessage: "hello")
        XCTAssertEqual(model.configs.first?.thinking, true)

        defaults.removeObject(forKey: ThinkingSetting.key)
        await orch.run(userMessage: "hello again")
        XCTAssertEqual(model.configs.last?.thinking, false, "thinking is off by default")
    }

    func testApplyingThinkingSettingReadsTheSwitch() {
        let suite = UserDefaults(suiteName: "thinking-\(UUID().uuidString)")!
        XCTAssertFalse(GenerationConfig.chat.applyingThinkingSetting(suite).thinking)
        suite.set(true, forKey: ThinkingSetting.key)
        XCTAssertTrue(GenerationConfig.chat.applyingThinkingSetting(suite).thinking)
        XCTAssertFalse(GenerationConfig.chat.thinking, "the base config is untouched")
    }

    func testStoppedTurnSavesNoDetails() async {
        let orch = AgentOrchestrator(model: ScriptedModel(), sessionsDirectory: tempDir())
        let run = Task { await orch.run(userMessage: "hello there") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        orch.cancel()
        await run.value
        XCTAssertFalse(orch.messages.contains { $0.details != nil })
    }

    // MARK: - Restored chats keep their details

    func testDetailsAreRestoredWithTheChat() async {
        let dir = tempDir()
        let orch = AgentOrchestrator(model: ScriptedModel(), sessionsDirectory: dir)
        await orch.run(userMessage: "hello there")
        let saved = orch.messages.last(where: { $0.role == .assistant })?.details
        XCTAssertNotNil(saved)

        let restored = AgentOrchestrator(model: ScriptedModel(), sessionsDirectory: dir)
        restored.loadActiveSessionFromDisk()
        XCTAssertEqual(restored.messages.last(where: { $0.role == .assistant })?.details, saved)
    }

    func testOldMessagesWithoutDetailsStillDecode() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"assistant","content":"Hi","timestamp":0,"isStreaming":false}"#
        let message = try JSONDecoder().decode(AgentMessage.self, from: Data(old.utf8))
        XCTAssertEqual(message.content, "Hi")
        XCTAssertNil(message.details)
        XCTAssertNil(message.reasoning)
    }

    func testDetailsRoundTrip() throws {
        var message = AgentMessage.assistant("Answer")
        message.details = AnswerDetails(tier: .onDevice, modelName: "Gemma 4 E4B (LiteRT-LM)", backend: "GPU",
                                        route: "Chat", memoryNotes: 2, toolsUsed: ["calculator"], destinations: [],
                                        firstWordMs: 1200, totalMs: 3400, tokensIn: 300, tokensOut: 60,
                                        writeMs: 2000, readMs: 1000, counted: true, completedAt: Date(timeIntervalSince1970: 100))
        message.reasoning = "thinking"
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.details, message.details)
        XCTAssertEqual(decoded.reasoning, "thinking")
    }

    // MARK: - Wording

    func testCaptionAndWhereItWent() {
        var d = AnswerDetails(tier: .onDevice, modelName: "Gemma 4 E4B (LiteRT-LM)")
        XCTAssertEqual(AnswerDetailsText.caption(d), "On device · Gemma 4 E4B")
        var timed = d
        timed.tokensOut = 94; timed.writeMs = 10_000
        XCTAssertEqual(AnswerDetailsText.caption(timed), "On device · Gemma 4 E4B · 9.4 tok/s", "speed, like AI Edge Gallery")
        XCTAssertEqual(AnswerDetailsText.whereItWent(d), "Nothing left your device")
        d.destinations = ["MCP · DeepWiki"]
        XCTAssertEqual(AnswerDetailsText.whereItWent(d), "1 item left your device · to MCP · DeepWiki")
        d.destinations = ["MCP · DeepWiki", "MCP · DeepWiki", "REST · Weather"]
        XCTAssertEqual(AnswerDetailsText.whereItWent(d), "3 items left your device · to MCP · DeepWiki and REST · Weather")
        XCTAssertTrue(d.leftDevice)

        let cloud = AnswerDetails(tier: .cloud, modelName: "Gemini")
        XCTAssertEqual(AnswerDetailsText.caption(cloud), "Cloud · Gemini")
        XCTAssertEqual(AnswerDetailsText.whereItWent(cloud), "Sent to Gemini (Google)")
        XCTAssertEqual(AnswerDetailsText.whoAnswered(cloud), "Gemini · in the cloud")
    }

    func testSpeedRowsMarkEstimates() {
        let d = AnswerDetails(tier: .onDevice, modelName: "M", firstWordMs: 2500, totalMs: 75_000,
                              tokensIn: 400, tokensOut: 85, writeMs: 10_000, readMs: 2000, counted: false, thoughtMs: 12_300)
        let rows = Dictionary(uniqueKeysWithValues: AnswerDetailsText.speedRows(d).map { ($0.label, $0.value) })
        XCTAssertEqual(rows["Thinking"], "12 s")
        XCTAssertEqual(rows["First word"], "2.5 s")
        XCTAssertEqual(rows["Writing"], "about 8.5 tokens/s")
        XCTAssertEqual(rows["Reading"], "about 200 tokens/s")
        XCTAssertEqual(rows["Tokens"], "about 400 in · 85 out")
        XCTAssertEqual(rows["Total"], "1 min 15 s")
        XCTAssertEqual(AnswerDetailsText.memory(AnswerDetails(tier: .onDevice, modelName: "M", memoryNotes: 1)), "Used 1 note from Memory")
        XCTAssertNil(AnswerDetailsText.memory(AnswerDetails(tier: .onDevice, modelName: "M", memoryNotes: 0)))
    }
}
