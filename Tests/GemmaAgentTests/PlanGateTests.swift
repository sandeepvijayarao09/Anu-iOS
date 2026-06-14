import XCTest
@testable import GemmaAgent

final class PlanGateTests: XCTestCase {

    private func task(_ type: TaskType, _ conf: Double = 0.8) -> TaskClassification {
        TaskClassification(type: type, confidence: conf)
    }

    // MARK: - Should plan

    func testSequencingLanguageTriggers() {
        XCTAssertTrue(PlanGate.shouldPlan(
            task: task(.webInfo),
            message: "search the latest AI news and then write me a short summary"))
    }

    func testTwoDistinctDomainsTrigger() {
        XCTAssertTrue(PlanGate.shouldPlan(
            task: task(.webInfo),
            message: "look up tomorrow's weather and add a reminder to bring an umbrella"))
    }

    func testNumberedListTriggers() {
        let msg = "Please do these:\n1. find the population of France\n2. divide it by two"
        XCTAssertTrue(PlanGate.shouldPlan(task: task(.generalQA, 0.5), message: msg))
    }

    // MARK: - Should NOT plan (fast path stays fast)

    func testSingleCalculationDoesNotTrigger() {
        XCTAssertFalse(PlanGate.shouldPlan(task: task(.math), message: "calculate 15 * 3"))
    }

    func testSingleSearchDoesNotTrigger() {
        XCTAssertFalse(PlanGate.shouldPlan(task: task(.webInfo), message: "what's the current bitcoin price"))
    }

    func testGreetingDoesNotTrigger() {
        XCTAssertFalse(PlanGate.shouldPlan(task: task(.casualChat), message: "hey how is it going"))
    }

    func testSingleDomainLongMessageDoesNotTrigger() {
        // Long but only one domain (web) and no sequencing/list → single-shot.
        XCTAssertFalse(PlanGate.shouldPlan(
            task: task(.webInfo),
            message: "can you look up the latest news about the current weather situation please"))
    }
}
