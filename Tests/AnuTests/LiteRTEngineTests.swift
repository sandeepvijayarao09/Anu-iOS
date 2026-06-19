import XCTest
@testable import Anu

/// Opt-in raw engine test for the bundled real model (Gemma 4 E4B via LiteRT
/// when present). Drives the engine through ModelFactory/LocalLanguageModel —
/// no MediaPipe types needed, so this builds without pods integration.
/// Run with: TEST_RUNNER_REAL_MODEL_TEST=1 xcodebuild ... -only-testing:AnuTests/LiteRTEngineTests
final class LiteRTEngineTests: XCTestCase {

    func testRealEngineGeneratesText() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["REAL_MODEL_TEST"] == "1",
            "Set REAL_MODEL_TEST=1 to run the real engine smoke test"
        )

        let model = ModelFactory.makeModel()
        print("ENGINE under test: \(model.modelName)")
        XCTAssertFalse(model.modelName.contains("Scripted") || model.modelName.contains("No Model"), "a real model should be bundled")

        let loadStart = Date()
        try await model.load()
        print("ENGINE load time: \(Date().timeIntervalSince(loadStart))s")

        let genStart = Date()
        var output = ""
        var chunkCount = 0
        let stream = try await model.generate(
            prompt: "<start_of_turn>user\nWhat is the capital of France? Answer in one word.<end_of_turn>\n<start_of_turn>model\n",
            config: .default
        )
        for await chunk in stream {
            output += chunk
            chunkCount += 1
            if output.count > 200 { break }
        }
        let dt = Date().timeIntervalSince(genStart)
        print("ENGINE generation: \(chunkCount) chunks in \(dt)s")
        print("ENGINE OUTPUT: '\(output)'")

        XCTAssertFalse(output.isEmpty, "engine produced no output")
        XCTAssertTrue(output.contains("Paris"), "expected Paris in: \(output)")
    }

    /// Reproduces the in-app condition: the full agent prompt (system prompt
    /// folded into the first user turn, tool schemas, JSON instructions).
    /// Guards against the degenerate-repetition failure seen with default
    /// engine sampling.
    func testRealEngineHandlesAgentPrompt() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["REAL_MODEL_TEST"] == "1",
            "Set REAL_MODEL_TEST=1 to run the real engine smoke test"
        )

        let model = ModelFactory.makeModel()
        try XCTSkipIf(model.modelName.contains("Scripted") || model.modelName.contains("No Model"), "needs a bundled real model")
        try await model.load()

        let prompt = await MainActor.run { () -> String in
            let registry = ToolRegistry()
            registry.register(CalculatorTool())
            registry.register(WebSearchTool())
            return GemmaChatTemplate.format(messages: [.user("Hi")], tools: registry.allTools)
        }

        var output = ""
        let stream = try await model.generate(prompt: prompt, config: .default)
        for await chunk in stream {
            output += chunk
            if output.count > 400 { break }
        }
        print("AGENT-PROMPT OUTPUT: '\(output)'")

        XCTAssertFalse(output.isEmpty)
        Self.assertNotDegenerate(output)
    }

    /// Reproduces the exact in-app CHAT path: persona folded into the first user
    /// turn via `formatChat`, generated with `.chat` (the hotter casual preset).
    /// This is the path "Hi" takes — the one that produced `<end<end<end` garbage.
    func testRealEngineChatPath() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["REAL_MODEL_TEST"] == "1",
            "Set REAL_MODEL_TEST=1 to run the real engine smoke test"
        )

        let model = ModelFactory.makeModel()
        try XCTSkipIf(model.modelName.contains("Scripted") || model.modelName.contains("No Model"), "needs a bundled real model")
        try await model.load()

        let prompt = GemmaChatTemplate.formatChat(messages: [.user("Hi")])
        var output = ""
        let stream = try await model.generate(prompt: prompt, config: .chat)
        for await chunk in stream {
            output += chunk
            if output.count > 400 { break }
        }
        print("CHAT-PATH OUTPUT: '\(output)'")

        XCTAssertFalse(output.isEmpty)
        Self.assertNotDegenerate(output)
    }

    /// Reproduces the REAL "completely failing" bug: a second consecutive chat
    /// turn on the SAME model instance reuses the LiteRT session (append-delta /
    /// KV-cache reuse). In the field this produced `<end<end<end` / `Anu Anu Anu`
    /// garbage while the first (fresh-session) turn was clean.
    func testRealEngineMultiTurnReuse() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["REAL_MODEL_TEST"] == "1",
            "Set REAL_MODEL_TEST=1 to run the real engine smoke test"
        )

        let model = ModelFactory.makeModel()
        try XCTSkipIf(model.modelName.contains("Scripted") || model.modelName.contains("No Model"), "needs a bundled real model")
        try await model.load()

        func generate(_ messages: [AgentMessage]) async throws -> String {
            let prompt = GemmaChatTemplate.formatChat(messages: messages)
            var out = ""
            let stream = try await model.generate(prompt: prompt, config: .chat)
            for await chunk in stream {
                out += chunk
                if out.count > 400 { break }
            }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Turn 1 — fresh session.
        let turn1 = try await generate([.user("Hi")])
        print("REUSE TURN1: '\(turn1)'")
        Self.assertNotDegenerate(turn1)

        // Turn 2 — same conversation continued. This is the path that used to
        // fail: either degenerate KV-cache garbage, or a thrown
        // "AddQueryChunk before PredictDone" / "generation already in progress".
        let turn2 = try await generate([.user("Hi"), .assistant(turn1), .user("What is 2 plus 2?")])
        print("REUSE TURN2: '\(turn2)'")
        Self.assertNotDegenerate(turn2)
        XCTAssertFalse(turn2.contains("[Generation error"), "engine left busy across turns: \(turn2)")
        XCTAssertTrue(turn2.contains("4"), "expected the answer 4 in: \(turn2)")

        // Turn 3 — one more multi-turn hop, to be sure the engine stays free.
        let turn3 = try await generate([.user("Hi"), .assistant(turn1), .user("What is 2 plus 2?"), .assistant(turn2), .user("Thanks!")])
        print("REUSE TURN3: '\(turn3)'")
        Self.assertNotDegenerate(turn3)
        XCTAssertFalse(turn3.contains("[Generation error"), "engine left busy across turns: \(turn3)")
    }

    /// Degeneration guard: neither a dominant repeated word nor a flood of the
    /// `<end…`/role-label fragments seen in the failing screenshot.
    /// `as Character` keeps `.split` on the stdlib overload — `String` conforms
    /// to RegexComponent, and the regex overload would pull in (and require
    /// linking) RegexBuilder.
    static func assertNotDegenerate(_ output: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(output.contains("<end<end"), "output emitting raw end-token fragments: \(output.prefix(200))", file: file, line: line)
        let words = output.lowercased().split(separator: " " as Character)
        if words.count >= 10 {
            let counts = Dictionary(grouping: words, by: { $0 }).mapValues(\.count)
            let maxRepeat = counts.values.max() ?? 0
            XCTAssertLessThan(Double(maxRepeat) / Double(words.count), 0.5,
                              "output looks degenerate: \(output.prefix(200))", file: file, line: line)
        }
    }
}
