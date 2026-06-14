import XCTest
@testable import GemmaAgent

final class ResponseParserTests: XCTestCase {

    func testPlainAnswerRoutesLocally() {
        let decision = ResponseParser.parse("The capital of France is Paris.")
        guard case .answerLocally(let answer) = decision else {
            return XCTFail("expected answerLocally")
        }
        XCTAssertTrue(answer.contains("Paris"))
    }

    func testBareToolCallIsExtracted() {
        let raw = #"{"tool_call": {"name": "calculator", "arguments": {"expression": "2 + 2"}}}"#
        guard case .callTool(let call) = ResponseParser.parse(raw) else {
            return XCTFail("expected callTool")
        }
        XCTAssertEqual(call.name, "calculator")
        XCTAssertEqual(call.arguments["expression"]?.stringValue, "2 + 2")
    }

    func testToolCallInsideCodeFence() {
        let raw = """
        Sure, let me calculate that.
        ```json
        {"tool_call": {"name": "calculator", "arguments": {"expression": "9 * 9"}}}
        ```
        """
        guard case .callTool(let call) = ResponseParser.parse(raw) else {
            return XCTFail("expected callTool from fenced JSON")
        }
        XCTAssertEqual(call.name, "calculator")
    }

    func testEscalationMapsToGeminiDecision() {
        let raw = #"{"tool_call": {"name": "escalate_to_gemini", "arguments": {"task": "write an essay", "context": "user request"}}}"#
        guard case .escalateToGemini(let task, let context) = ResponseParser.parse(raw) else {
            return XCTFail("expected escalateToGemini")
        }
        XCTAssertEqual(task, "write an essay")
        XCTAssertEqual(context, "user request")
    }

    func testMalformedJSONFallsBackToLocalAnswer() {
        let raw = #"{"tool_call": {"name": "calculator", BROKEN"#
        guard case .answerLocally = ResponseParser.parse(raw) else {
            return XCTFail("malformed tool call should fall back to a local answer")
        }
    }

    func testNestedArgumentsSurvive() {
        let raw = #"{"tool_call": {"name": "web_search", "arguments": {"query": "swift 6", "num_results": 5}}}"#
        guard case .callTool(let call) = ResponseParser.parse(raw) else {
            return XCTFail("expected callTool")
        }
        XCTAssertEqual(call.arguments["num_results"]?.intValue, 5)
    }

    func testTruncatedToolCallDoesNotCrash() {
        // Prose before an UNCLOSED tool_call (cut off by maxNextTokens) used
        // to trap on an invalid range slice. Must fall back to a local answer.
        let raw = #"Sure, let me do that. {"tool_call": {"name": "calculator", "arguments": {"expression": "2+2""#
        guard case .answerLocally = ResponseParser.parse(raw) else {
            return XCTFail("truncated tool call must degrade to a local answer, not crash")
        }
    }

    func testToolCallKeywordWithoutBracesDoesNotCrash() {
        let raw = "I will use a tool_call here but never open a brace"
        _ = ResponseParser.parse(raw) // must not trap
    }

}
