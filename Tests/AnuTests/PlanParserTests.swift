import XCTest
@testable import Anu

final class PlanParserTests: XCTestCase {

    func testParsesValidPlan() {
        let raw = #"{"plan":[{"step":1,"description":"search news","specialist":"researcher","tool_hint":"web_search"},{"step":2,"description":"write summary","specialist":"writer"}]}"#
        let plan = PlanParser.parse(raw, goal: "g")
        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertEqual(plan.steps[0].specialist, .researcher)
        XCTAssertEqual(plan.steps[0].toolHint, "web_search")
        XCTAssertEqual(plan.steps[1].specialist, .writer)
        XCTAssertNil(plan.steps[1].toolHint)
    }

    func testMalformedFallsBackToSingleStep() {
        let plan = PlanParser.parse("I won't give you JSON, sorry.", goal: "do the thing")
        XCTAssertTrue(plan.isSingleStep)
        XCTAssertEqual(plan.steps.first?.specialist, .generalist)
        XCTAssertEqual(plan.steps.first?.description, "do the thing")
    }

    func testEmptyPlanFallsBack() {
        let plan = PlanParser.parse(#"{"plan":[]}"#, goal: "the goal")
        XCTAssertTrue(plan.isSingleStep)
        XCTAssertEqual(plan.steps.first?.description, "the goal")
    }

    func testUnknownSpecialistBecomesGeneralist() {
        let raw = #"{"plan":[{"step":1,"description":"do x","specialist":"wizard"}]}"#
        let plan = PlanParser.parse(raw, goal: "g")
        XCTAssertEqual(plan.steps.first?.specialist, .generalist)
    }

    func testTolerantSpecialistSynonyms() {
        let raw = #"{"plan":[{"step":1,"description":"x","specialist":"web research"},{"step":2,"description":"y","specialist":"programmer"}]}"#
        let plan = PlanParser.parse(raw, goal: "g")
        XCTAssertEqual(plan.steps[0].specialist, .researcher)
        XCTAssertEqual(plan.steps[1].specialist, .coder)
    }

    func testParsesBareArray() {
        let raw = #"[{"step":1,"description":"compute the mean","specialist":"mathematician"}]"#
        let plan = PlanParser.parse(raw, goal: "g")
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps.first?.specialist, .mathematician)
    }

    func testCodeFenceTolerated() {
        let raw = "Here is the plan:\n```json\n{\"plan\":[{\"step\":1,\"description\":\"x\",\"specialist\":\"coder\"}]}\n```"
        let plan = PlanParser.parse(raw, goal: "g")
        XCTAssertEqual(plan.steps.first?.specialist, .coder)
    }

    func testTruncatedJSONFallsBack() {
        // Unbalanced braces (e.g. cut off by max tokens) must not crash/slice.
        let raw = #"{"plan":[{"step":1,"description":"x","specialist":"writer""#
        let plan = PlanParser.parse(raw, goal: "fallback goal")
        XCTAssertTrue(plan.isSingleStep)
        XCTAssertEqual(plan.steps.first?.description, "fallback goal")
    }
}
