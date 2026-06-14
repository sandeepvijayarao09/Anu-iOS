import XCTest
@testable import GemmaAgent

@MainActor
final class PlannerTests: XCTestCase {

    func testMakePlanParsesModelJSON() async {
        let model = QueuedMockModel([
            #"{"plan":[{"step":1,"description":"a","specialist":"researcher"},{"step":2,"description":"b","specialist":"writer"}]}"#
        ])
        let plan = await Planner(model: model).makePlan(goal: "do a then b")
        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertEqual(plan.steps[0].specialist, .researcher)
        XCTAssertEqual(plan.steps[1].specialist, .writer)
    }

    func testPlannerPromptCarriesSentinelAndNoTools() async {
        let model = QueuedMockModel([#"{"plan":[{"step":1,"description":"x","specialist":"generalist"}]}"#])
        _ = await Planner(model: model).makePlan(goal: "g")
        let prompt = model.capturedPrompts.first ?? ""
        XCTAssertTrue(prompt.contains("[[PLANNER]]"))
        XCTAssertFalse(prompt.contains("\"tool_call\""), "planner must not advertise the tool protocol")
    }

    func testMakePlanFallsBackOnGarbage() async {
        let model = QueuedMockModel(["sorry, no structured output for you"])
        let plan = await Planner(model: model).makePlan(goal: "the original goal")
        XCTAssertTrue(plan.isSingleStep)
        XCTAssertEqual(plan.steps.first?.description, "the original goal")
        XCTAssertEqual(plan.steps.first?.specialist, .generalist)
    }

    func testStepCountCapped() async {
        // 8 steps emitted → capped to Planner.maxSteps.
        let many = (1...8).map { #"{"step":\#($0),"description":"s\#($0)","specialist":"generalist"}"# }
            .joined(separator: ",")
        let model = QueuedMockModel(["{\"plan\":[\(many)]}"])
        let plan = await Planner(model: model).makePlan(goal: "g")
        XCTAssertLessThanOrEqual(plan.steps.count, Planner.maxSteps)
    }
}
