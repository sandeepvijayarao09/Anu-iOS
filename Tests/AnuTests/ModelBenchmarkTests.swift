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
        let read = usage.flatMap { u in AnswerDetails.rate(u.promptTokens, u.firstOutputMs) }
        let write = usage.flatMap { u in AnswerDetails.rate(u.outputTokens, u.decodeMs) }
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
