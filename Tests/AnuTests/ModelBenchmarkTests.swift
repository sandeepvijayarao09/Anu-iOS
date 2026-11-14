import XCTest
@testable import Anu

/// The real model, measured the way Google AI Edge Gallery's benchmark does
/// (load time, time to first token, read and write tokens a second) plus a
/// fixed quality set, repeated `BENCH_RUNS` times. Writes a Markdown report
/// to the test's temporary folder and prints its path.
///
/// Run with:
///   TEST_RUNNER_REAL_MODEL_TEST=1 TEST_RUNNER_BENCH_RUNS=20 xcodebuild test ...
///     -only-testing:AnuTests/ModelBenchmarkTests
final class ModelBenchmarkTests: XCTestCase {

    /// One question and what a right answer contains (any of the words).
    struct Case {
        let name: String
        let messages: [AgentMessage]
        let expectAny: [String]
    }

    static let cases: [Case] = [
        Case(name: "fact", messages: [.user("What is the capital of Japan? One word.")], expectAny: ["tokyo"]),
        Case(name: "math", messages: [.user("What is 17 times 6? Just the number.")], expectAny: ["102"]),
        Case(name: "instruction", messages: [.user("Reply with only the word YES in capitals.")], expectAny: ["YES"]),
        Case(name: "recall", messages: [
            .user("My dog is called Biscuit."), .assistant("Biscuit is a lovely name!"),
            .user("What's my dog's name?"),
        ], expectAny: ["biscuit"]),
        Case(name: "reasoning", messages: [
            .user("Anna is taller than Ben. Ben is taller than Cara. Who is shortest? One word."),
        ], expectAny: ["cara"]),
        Case(name: "date (knows today)", messages: [.user("Which year is it now? Just the year.")],
             expectAny: [String(Calendar.current.component(.year, from: Date()))]),
        Case(name: "summary", messages: [
            .user("Summarise in one short sentence: The meeting moved to Friday because the room was booked on Thursday."),
        ], expectAny: ["friday"]),
    ]

    struct Sample {
        let name: String
        let ok: Bool
        let firstMs: Int
        let readRate: Double?
        let writeRate: Double?
        let reused: Bool
    }

    func testBenchmarkLikeGallery() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["REAL_MODEL_TEST"] == "1", "Set REAL_MODEL_TEST=1 to benchmark the real model")
        let runs = max(1, Int(env["BENCH_RUNS"] ?? "") ?? 3)

        let model = ModelFactory.makeModel()
        try XCTSkipIf(model.modelName.contains("Scripted") || model.modelName.contains("No Model"), "needs a bundled real model")
        let loadStart = Date()
        try await model.load()
        let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)

        var samples: [Sample] = []
        for _ in 0..<runs {
            for item in Self.cases {
                samples.append(try await Self.measure(model, item.name, item.messages, expect: item.expectAny))
            }
            // Agent turns: the right tool, read from the model's own output.
            for item in Self.toolCases {
                samples.append(try await Self.measureTool(model, item))
            }
            // A follow-up in the same chat: the engine should read on, not start over.
            let first: [AgentMessage] = [.user("Name one planet.")]
            let answer = try await Self.answer(model, first)
            samples.append(try await Self.measure(model, "follow-up", first + [.assistant(answer), .user("Name another one.")],
                                                  expect: ["mercury", "venus", "earth", "mars", "jupiter", "saturn", "uranus", "neptune"]))
        }

        let report = Self.report(model: model.modelName, context: model.contextTokens, loadMs: loadMs, runs: runs, samples: samples)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("anu-benchmark.md")
        try report.write(to: url, atomically: true, encoding: .utf8)
        print("BENCHMARK REPORT: \(url.path)\n\(report)")

        let accuracy = Double(samples.filter(\.ok).count) / Double(samples.count)
        XCTAssertGreaterThanOrEqual(accuracy, 0.8, "quality fell below 80%:\n\(report)")
    }

    /// A request and the tool a right answer calls.
    struct ToolCase {
        let name: String
        let message: String
        let tool: String
    }

    static let toolCases: [ToolCase] = [
        ToolCase(name: "tool: calculator", message: "What is 23.5% of 812.4? Use the calculator.", tool: "calculator"),
        ToolCase(name: "tool: web search", message: "Search the web for the latest news about the Mars rover.", tool: "web_search"),
        ToolCase(name: "tool: fresh facts", message: "Look up who won the most recent Nobel Prize in Physics.", tool: "web_search"),
    ]

    static func measureTool(_ model: any LocalLanguageModel, _ item: ToolCase) async throws -> Sample {
        let tools: [any Tool] = [CalculatorTool(), WebSearchTool(), DateTimeTool()]
        let prompt = GemmaChatTemplate.format(messages: [.user(item.message)], tools: tools)
        let started = Date()
        var first: Date?
        var out = ""
        for await piece in try await model.generate(prompt: prompt, config: .agentFromSettings) {
            if first == nil { first = Date() }
            out += piece
            if out.count > 600 { break }
        }
        let ok: Bool
        if case .callTool(let call) = ResponseParser.parse(out) { ok = call.name == item.tool } else { ok = false }
        if !ok { print("BENCH TOOL MISS \(item.name): \(out.prefix(200))") }
        let usage = await model.lastUsage()
        return Sample(name: item.name, ok: ok, firstMs: Int(((first ?? Date()).timeIntervalSince(started)) * 1000),
                      readRate: usage.flatMap { AnswerDetails.rate($0.promptTokens, $0.firstOutputMs) },
                      writeRate: usage.flatMap { AnswerDetails.rate($0.outputTokens, $0.decodeMs) }, reused: false)
    }

    // MARK: Measuring

    static func answer(_ model: any LocalLanguageModel, _ messages: [AgentMessage]) async throws -> String {
        var out = ""
        for await piece in try await model.generate(prompt: GemmaChatTemplate.formatChat(messages: messages), config: .chat) {
            out += piece
            if out.count > 600 { break }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func measure(_ model: any LocalLanguageModel, _ name: String, _ messages: [AgentMessage],
                        expect: [String]) async throws -> Sample {
        let started = Date()
        var first: Date?
        var out = ""
        for await piece in try await model.generate(prompt: GemmaChatTemplate.formatChat(messages: messages), config: .chat) {
            if first == nil { first = Date() }
            out += piece
            if out.count > 600 { break }
        }
        let usage = await model.lastUsage()
        let firstMs = Int(((first ?? Date()).timeIntervalSince(started)) * 1000)
        let ok = expect.contains { out.range(of: $0, options: .caseInsensitive) != nil }
        if !ok { print("BENCH MISS \(name): \(out.prefix(200))") }
        let read = usage.flatMap { u in AnswerDetails.rate(u.promptTokens, u.firstOutputMs) }
        // A one-word answer has no meaningful write speed.
        let write = usage.flatMap { u in (u.outputTokens ?? 0) >= 5 ? AnswerDetails.rate(u.outputTokens, u.decodeMs) : nil }
        // A follow-up the engine read on from reads only the new turn.
        let reused = (usage?.promptTokens ?? .max) < 200 && messages.count > 1
        return Sample(name: name, ok: ok, firstMs: firstMs, readRate: read, writeRate: write, reused: reused)
    }

    // MARK: Report

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted[sorted.count / 2]
    }

    static func report(model: String, context: Int, loadMs: Int, runs: Int, samples: [Sample]) -> String {
        func fmt(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "–" }
        var lines = [
            "# Anu model benchmark",
            "",
            "Model: \(model) · context \(context) tokens · \(runs) runs · load \(loadMs) ms",
            "",
            "| Case | Right | Median first token (ms) | Read tok/s | Write tok/s |",
            "|---|---|---|---|---|",
        ]
        let names = samples.map(\.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        for name in names {
            let group = samples.filter { $0.name == name }
            let right = group.filter(\.ok).count
            lines.append("| \(name) | \(right)/\(group.count) | \(fmt(median(group.map { Double($0.firstMs) }))) | "
                         + "\(fmt(median(group.compactMap(\.readRate)))) | \(fmt(median(group.compactMap(\.writeRate)))) |")
        }
        let followUps = samples.filter { $0.name == "follow-up" }
        lines += ["", "Follow-ups that read on from the live chat: \(followUps.filter(\.reused).count)/\(followUps.count)",
                  "Overall right: \(samples.filter(\.ok).count)/\(samples.count)"]
        return lines.joined(separator: "\n")
    }
}
