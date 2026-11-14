import XCTest
@testable import Anu

/// Where a turn's time goes, through the whole app (router, memory, tools,
/// the agent loop), with the real model: a short everyday conversation, and
/// for each turn the time to the first word and to the end, how many model
/// calls it took, what they read, and the time outside the model.
///
/// Run with:
///   TEST_RUNNER_REAL_MODEL_TEST=1 xcodebuild test ... -only-testing:AnuTests/TurnLatencyTests
@MainActor
final class TurnLatencyTests: XCTestCase {

    static let conversation = [
        "Hi! I'm planning a trip to Japan next month.",
        "What's the best time of year to see cherry blossoms there?",
        "What's on my calendar today?",
        "What about tomorrow?",
        "And which city should I visit first?",
        "What's 15% of 2400?",
        "Thanks. Sum up what we talked about in two sentences.",
    ]

    func testWhereATurnsTimeGoes() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["REAL_MODEL_TEST"] == "1",
                          "Set REAL_MODEL_TEST=1 to time turns on the real model")
        let defaults = UserDefaults.standard
        let key = ModelManager.selectionKey
        let saved = defaults.string(forKey: key)
        defaults.set(ProcessInfo.processInfo.environment["BENCH_MODEL"] ?? "liteRT", forKey: key)
        defer { defaults.set(saved, forKey: key) }

        let model = ModelFactory.makeModel()
        try XCTSkipIf(model.modelName.contains("Scripted") || model.modelName.contains("No Model"), "needs a real model")
        let loadStart = Date()
        try await model.load()
        print("LATENCY model \(model.modelName), load \(Int(Date().timeIntervalSince(loadStart) * 1000)) ms")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let orchestrator = AgentOrchestrator(model: model, sessionsDirectory: dir)
        await orchestrator.reloadConnectors()
        // As at launch: once the model is in, it reads the chat opening ahead.
        let warmStart = Date()
        orchestrator.warmUp()
        await orchestrator.preparing?.value
        print("LATENCY opening read ahead in \(Int(Date().timeIntervalSince(warmStart) * 1000)) ms (nobody waiting)")

        var rows = ["| # | Message | Route | Calls | First word ms | Total ms | Read tokens | Read ms | Write ms | Outside model ms |",
                    "|---|---|---|---|---|---|---|---|---|---|"]
        for (i, message) in Self.conversation.enumerated() {
            let started = Date()
            await orchestrator.run(userMessage: message)
            let total = Int(Date().timeIntervalSince(started) * 1000)
            let answer = orchestrator.messages.last { $0.role == .assistant }
            let d = answer?.details
            let calls = orchestrator.reasoningSteps.filter { $0.kind == .tool || $0.kind == .final }.count
            let inModel = (d?.readMs ?? 0) + (d?.writeMs ?? 0)
            rows.append("| \(i + 1) | \(message.prefix(40)) | \(d?.route ?? "–") | \(calls) | \(d?.firstWordMs.map(String.init) ?? "–") | "
                        + "\(total) | \(d?.tokensIn.map(String.init) ?? "–") | \(d?.readMs.map(String.init) ?? "–") | "
                        + "\(d?.writeMs.map(String.init) ?? "–") | \(total - inModel) |")
            print("LATENCY turn \(i + 1) answer: \((answer?.content ?? "").prefix(120))")
            for step in orchestrator.reasoningSteps {
                let at = Int(step.timestamp.timeIntervalSince(started) * 1000)
                print("LATENCY   +\(at) ms \(step.kind) \((step.action ?? "").prefix(70))")
            }
        }
        print("LATENCY REPORT\n" + rows.joined(separator: "\n"))
    }
}

/// What tool descriptions cost (no model needed).
@MainActor
final class ToolPromptSizeTests: XCTestCase {
    func testPrintToolSizes() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let orch = AgentOrchestrator(model: QueuedMockModel(["ok"]), sessionsDirectory: dir)
        await orch.reloadConnectors()
        let all = orch.toolRegistry.allTools
        for tool in all.sorted(by: { $0.name < $1.name }) {
            print("TOOLSIZE \(tool.name) \(GemmaChatTemplate.toolProtocolBlock(tools: [tool]).count - GemmaChatTemplate.toolCallFormat.count)")
        }
        for message in TurnLatencyTests.conversation {
            let picked = ToolSelector.select(all, turns: [message], escalation: nil)
            print("TOOLPICK \(message.prefix(40)) -> \(picked.map(\.name)) \(GemmaChatTemplate.toolProtocolBlock(tools: picked).count) chars")
        }
    }
}

