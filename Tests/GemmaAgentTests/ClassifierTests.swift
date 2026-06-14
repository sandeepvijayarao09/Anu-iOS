import XCTest
@testable import GemmaAgent

@MainActor
final class TaskClassifierTests: XCTestCase {

    private func type(of text: String) -> TaskType {
        TaskClassifier.shared.classify(text).type
    }

    func testGreetingIsCasualChat() {
        XCTAssertEqual(type(of: "hey, how's it going?"), .casualChat)
    }

    func testArithmeticIsMath() {
        XCTAssertEqual(type(of: "what's 37 * 14 minus 12"), .math)
    }

    func testNewsIsWebInfo() {
        XCTAssertEqual(type(of: "look up today's tech headlines"), .webInfo)
    }

    func testCodingIsCodeGen() {
        XCTAssertEqual(type(of: "write a swift function that reverses a string"), .codeGen)
    }

    func testEssayIsLongWriting() {
        XCTAssertEqual(type(of: "draft a short essay on climate change"), .longWriting)
    }

    func testConfidenceIsBounded() {
        let c = TaskClassifier.shared.classify("hello!").confidence
        XCTAssertGreaterThanOrEqual(c, 0)
        XCTAssertLessThanOrEqual(c, 1.0001)
    }

    func testKeywordFallbackCoversAllTypes() {
        XCTAssertEqual(TaskClassifier.keywordFallback("calculate 5 + 5").type, .math)
        XCTAssertEqual(TaskClassifier.keywordFallback("search the latest news").type, .webInfo)
        XCTAssertEqual(TaskClassifier.keywordFallback("debug my code").type, .codeGen)
        XCTAssertEqual(TaskClassifier.keywordFallback("write an essay").type, .longWriting)
        XCTAssertEqual(TaskClassifier.keywordFallback("explain how engines work").type, .generalQA)
        XCTAssertEqual(TaskClassifier.keywordFallback("hey there").type, .casualChat)
    }
}

final class ModelClassifierTests: XCTestCase {

    private func route(_ type: TaskType, confidence: Double = 0.8, cloud: Bool = false) -> ModelRoute {
        ModelClassifier.route(
            task: TaskClassification(type: type, confidence: confidence),
            cloudAvailable: cloud
        )
    }

    func testChatStaysOnDevice() {
        XCTAssertEqual(route(.casualChat), .onDeviceChat)
        XCTAssertEqual(route(.generalQA), .onDeviceChat)
    }

    func testToolTasksUseAgentLoop() {
        XCTAssertEqual(route(.math), .onDeviceAgent)
        XCTAssertEqual(route(.webInfo), .onDeviceAgent)
    }

    func testHeavyGenerationPrefersCloudWhenAvailable() {
        XCTAssertEqual(route(.codeGen, cloud: true), .cloudEscalate)
        XCTAssertEqual(route(.longWriting, cloud: true), .cloudEscalate)
    }

    func testHeavyGenerationStaysLocalWithoutCloud() {
        XCTAssertEqual(route(.codeGen, cloud: false), .onDeviceChat)
        XCTAssertEqual(route(.longWriting, cloud: false), .onDeviceChat)
    }

    func testLowConfidenceFallsBackToAgent() {
        XCTAssertEqual(route(.casualChat, confidence: 0.2), .onDeviceAgent)
        XCTAssertEqual(route(.codeGen, confidence: 0.1, cloud: true), .onDeviceAgent)
    }
}
