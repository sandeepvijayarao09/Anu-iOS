import CryptoKit
import XCTest
@testable import Anu

/// Memory learned by a model that fills in the format itself (Apple's guided
/// generation): no parsing or repair, the same checks on what is kept, and
/// never by a model that answers off the phone.
@MainActor
final class GuidedMemoryExtractionTests: XCTestCase {
    /// Returns scripted facts (or throws), recording what it was asked.
    private final class GuidedModel: OnDeviceLanguageModel, GuidedFactExtracting, @unchecked Sendable {
        let modelName = "Guided"
        var facts: [ExtractedFact] = []
        var failure: Error?
        var onDevice = true
        var asked: [(message: String, instructions: String)] = []
        var runsOnDevice: Bool { onDevice }
        func load() async throws {}
        func generate(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String> {
            XCTFail("a guided model is never asked for text")
            return AsyncStream { $0.finish() }
        }
        func extractFacts(from message: String, instructions: String) async throws -> [ExtractedFact] {
            asked.append((message, instructions))
            if let failure { throw failure }
            return facts
        }
    }

    private func fact(_ predicate: String, _ value: String, quote: String) -> ExtractedFact {
        ExtractedFact(subject: "I", predicate: predicate, value: value, section: .preferences, quote: quote)
    }

    func testGuidedFactsAreCheckedLikeAnyOthers() async {
        let model = GuidedModel()
        model.facts = [fact("Diet", "vegetarian", quote: "I'm vegetarian"),
                       fact("lives_in", "Paris", quote: "I live in Paris"),       // not in the message
                       fact("wifi_password", "hunter2", quote: "hunter2")]       // never kept
        let result = await FactExtractor(model: model).extract("I'm vegetarian, and hunter2 is it")
        guard case .facts(let kept) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(kept.map(\.value), ["vegetarian"])
        XCTAssertEqual(kept.first?.subject, MemoryFact.user)
        XCTAssertEqual(kept.first?.predicate, "diet")
        XCTAssertEqual(model.asked.count, 1, "one call, no repair turn")
    }

    func testGuidedInstructionsCarryNoJSONOrSentinel() {
        let text = FactExtractor(model: GuidedModel()).guidedInstructions
        XCTAssertFalse(text.contains(FactExtractor.sentinel))
        XCTAssertFalse(text.contains("{\"facts\""), text)
        XCTAssertTrue(text.contains("Never include passwords"))
        XCTAssertTrue(text.contains("Today is"))
    }

    func testAFailedGuidedAnswerCountsAsAnAttempt() async {
        let model = GuidedModel()
        model.failure = ModelError.generationFailed("guardrail")
        let result = await FactExtractor(model: model).extract("I'm vegetarian")
        guard case .failed = result else { return XCTFail("\(result)") }
    }

    func testAModelOffThePhoneNeverLearns() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("guided-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MemoryStore(directory: dir, keys: StaticDataKey(key: SymmetricKey(size: .bits256)), embedder: nil)
        store.captureChat("I'm vegetarian, by the way")
        let model = GuidedModel()
        model.onDevice = false
        model.facts = [fact("diet", "vegetarian", quote: "I'm vegetarian")]
        let result = await MemoryLearner.process(store: store, model: model)
        XCTAssertTrue(result.noModel)
        XCTAssertTrue(model.asked.isEmpty)
        XCTAssertEqual(store.pendingCount, 1)
    }

    #if canImport(FoundationModels) && compiler(>=6.4)  // iOS 27 SDK APIs (Xcode 27)
    func testApplesModelLearnsOnlyOnThePhone() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { throw XCTSkip("needs iOS 27") }
        XCTAssertTrue(AppleFoundationModel(kind: .onDevice).runsOnDevice)
        XCTAssertFalse(AppleFoundationModel(kind: .privateCloud).runsOnDevice)
    }

    func testApplesGuidedFactMapsToAnExtractedFact() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { throw XCTSkip("needs iOS 27") }
        let moving = AppleFoundationModel.fact(.init(subject: "user", predicate: "lives_in", value: "Denver", section: "places",
                                                     quote: "moving to Denver", sensitive: false, single: true, starts: " 2026-12-01 "))
        XCTAssertEqual(moving, ExtractedFact(subject: "user", predicate: "lives_in", value: "Denver", section: .places,
                                             quote: "moving to Denver", single: true, starts: "2026-12-01"))
        let odd = AppleFoundationModel.fact(.init(subject: "Maya", predicate: "likes", value: "tea", section: "notes",
                                                  quote: "Maya likes tea", sensitive: false, single: false, starts: ""))
        XCTAssertEqual(odd.section, .people, "notes isn't a learned section; someone else's fact goes in people")
        XCTAssertNil(odd.starts)
    }
    #endif
}
