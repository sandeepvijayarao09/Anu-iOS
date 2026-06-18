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
        // Degeneration guard: no word should dominate the response
        // `as Character` keeps this on the stdlib overload — `String` conforms
        // to RegexComponent, and the regex overload would pull in (and require
        // linking) RegexBuilder.
        let words = output.lowercased().split(separator: " " as Character)
        if words.count >= 10 {
            let counts = Dictionary(grouping: words, by: { $0 }).mapValues(\.count)
            let maxRepeat = counts.values.max() ?? 0
            XCTAssertLessThan(Double(maxRepeat) / Double(words.count), 0.5,
                              "output looks degenerate: \(output.prefix(200))")
        }
    }
}
