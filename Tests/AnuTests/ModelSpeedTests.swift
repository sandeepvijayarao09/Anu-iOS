import XCTest
@testable import Anu

@MainActor
final class ModelSpeedTests: XCTestCase {

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "speed-\(UUID().uuidString)")!
    }

    private func details(model: String = "Gemma 4 E2B", rate: Double, counted: Bool = true) -> AnswerDetails {
        AnswerDetails(tier: .onDevice, modelName: model, firstWordMs: 1000, tokensIn: 200, tokensOut: Int(rate * 2),
                      writeMs: 2000, readMs: 1000, counted: counted, completedAt: Date())
    }

    func testMedian() {
        XCTAssertNil(SpeedSummary.median([]))
        XCTAssertEqual(SpeedSummary.median([3, 1, 2]), 2)
        XCTAssertEqual(SpeedSummary.median([4, 1, 3, 2]), 2.5)
    }

    func testRealUseIsTheMiddleOfTheLastTwentyAnswers() {
        let log = ModelSpeedLog(defaults: nil)
        for rate in 1...25 { log.record(details(rate: Double(rate))) }
        log.record(details(model: "Other", rate: 99))
        let summary = log.summary(for: "Gemma 4 E2B")
        XCTAssertEqual(summary?.answers, 20, "only the last 20 are kept")
        XCTAssertEqual(summary?.writeRate ?? 0, 15.5, accuracy: 1e-9, "the middle of 6...25")
        XCTAssertEqual(summary?.readRate ?? 0, 200, accuracy: 1e-9)
        XCTAssertEqual(summary?.firstWordMs, 1000)
        XCTAssertEqual(summary?.counted, true)
        XCTAssertEqual(log.summary(for: "Other")?.answers, 1)
        XCTAssertNil(log.summary(for: "Never used"))
    }

    func testCloudAnswersAreNotRealUse() {
        let log = ModelSpeedLog(defaults: nil)
        log.record(AnswerDetails(tier: .cloud, modelName: "Gemini", totalMs: 900))
        XCTAssertTrue(log.samples.isEmpty)
    }

    func testSpeedsPersistAcrossLaunches() {
        let defaults = suite()
        let log = ModelSpeedLog(defaults: defaults)
        log.record(details(rate: 10, counted: false))
        log.record(test: SpeedTestResult(readRate: 64, writeRate: 8.5, firstWordMs: 11_000, tokensIn: 250,
                                         tokensOut: 92, counted: true, at: Date()), model: "Gemma 4 E2B")
        let relaunched = ModelSpeedLog(defaults: defaults)
        XCTAssertEqual(relaunched.summary(for: "Gemma 4 E2B")?.counted, false)
        XCTAssertEqual(relaunched.tests["Gemma 4 E2B"]?.tokensOut, 92)
    }

    func testSpeedWording() {
        let result = SpeedTestResult(readRate: 64.4, writeRate: 8.52, firstWordMs: 11_000, tokensIn: 250,
                                     tokensOut: 92, counted: true, at: Date())
        XCTAssertEqual(SpeedTest.summary(result), "read 250 at 64 tokens/s · wrote 92 at 8.5 tokens/s · first word 11 s")
        let summary = SpeedSummary(answers: 2, writeRate: 9, readRate: nil, firstWordMs: 1500, counted: false)
        XCTAssertEqual(ModelSpeedSection.realUse(summary), "writes about 9.0 tokens/s · first word 1.5 s · 2 answers")
    }

    func testTestSpeedRunsTheFixedRequestBesideTheChat() async throws {
        let usage = GenerationUsage(promptTokens: 250, outputTokens: 92, counted: true, backend: "GPU",
                                    firstOutputMs: 4000, decodeMs: 10_000)
        let model = MeteredMockModel(["Mara kept the light."], usage: usage)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("speed-\(UUID().uuidString)")
        let orch = AgentOrchestrator(model: model, sessionsDirectory: dir)

        let result = try await orch.testSpeed()
        XCTAssertEqual(model.prompts.last, SpeedTest.prompt)
        XCTAssertTrue(SpeedTest.prompt.contains("Westmere"))
        XCTAssertEqual(model.configs.last?.topK, 1, "greedy, so runs compare")
        XCTAssertEqual(result.readRate ?? 0, 62.5, accuracy: 1e-9)
        XCTAssertEqual(result.writeRate ?? 0, 9.2, accuracy: 1e-9)
        XCTAssertTrue(result.counted)
        XCTAssertTrue(orch.messages.isEmpty, "Test speed leaves the chat alone")
        XCTAssertEqual(ModelSpeedLog.shared.tests["Metered Mock"]?.tokensOut, 92)
    }
}
