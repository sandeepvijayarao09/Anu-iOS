import XCTest
@testable import Anu

final class ScriptedModelTests: XCTestCase {

    private func collect(_ model: ScriptedModel, prompt: String) async throws -> String {
        var output = ""
        for await token in try await model.generate(prompt: prompt, config: .default) {
            output += token
        }
        return output
    }

    private func prompt(for messages: [AgentMessage]) -> String {
        GemmaChatTemplate.format(messages: messages, tools: [CalculatorTool(), WebSearchTool()])
    }

    func testMathMessageRoutesToCalculator() async throws {
        let model = ScriptedModel()
        let raw = try await collect(model, prompt: prompt(for: [.user("calculate 12 * 8 + 5")]))
        guard case .callTool(let call) = ResponseParser.parse(raw) else {
            return XCTFail("expected a tool call, got: \(raw.prefix(100))")
        }
        XCTAssertEqual(call.name, "calculator")
        XCTAssertEqual(call.arguments["expression"]?.stringValue?.contains("12"), true)
    }

    func testSearchMessageRoutesToWebSearch() async throws {
        let model = ScriptedModel()
        let raw = try await collect(model, prompt: prompt(for: [.user("search latest AI news")]))
        guard case .callTool(let call) = ResponseParser.parse(raw) else {
            return XCTFail("expected a tool call, got: \(raw.prefix(100))")
        }
        XCTAssertEqual(call.name, "web_search")
    }

    func testComplexTaskEscalatesToGemini() async throws {
        let model = ScriptedModel()
        let raw = try await collect(model, prompt: prompt(for: [.user("write me an essay about space")]))
        guard case .escalateToGemini(let task, _) = ResponseParser.parse(raw) else {
            return XCTFail("expected escalation, got: \(raw.prefix(100))")
        }
        XCTAssertTrue(task.contains("essay"))
    }

    func testGreetingAnswersLocally() async throws {
        let model = ScriptedModel()
        let raw = try await collect(model, prompt: prompt(for: [.user("hello there")]))
        guard case .answerLocally = ResponseParser.parse(raw) else {
            return XCTFail("expected a local answer, got: \(raw.prefix(100))")
        }
    }

    // MARK: - Pipeline sentinels

    func testPlannerSentinelReturnsPlanJSON() async throws {
        let model = ScriptedModel()
        let prompt = GemmaChatTemplate.format(
            messages: [.user("do a then b")], tools: [],
            systemPromptOverride: "You are the Planner. [[PLANNER]]")
        let raw = try await collect(model, prompt: prompt)
        let plan = PlanParser.parse(raw, goal: "g")
        XCTAssertGreaterThanOrEqual(plan.steps.count, 2)
    }

    func testCriticSentinelApprovesByDefault() async throws {
        let model = ScriptedModel()
        let prompt = GemmaChatTemplate.format(
            messages: [.user("the answer")], tools: [],
            systemPromptOverride: "You are the Critic. [[CRITIC]]")
        let raw = try await collect(model, prompt: prompt)
        XCTAssertEqual(Critic.parse(raw), .approved)
    }

    func testSynthSentinelReturnsProseNotToolCall() async throws {
        let model = ScriptedModel()
        let prompt = GemmaChatTemplate.format(
            messages: [.user("combine the steps")], tools: [],
            systemPromptOverride: "You are the Synthesizer. [[SYNTH]]")
        let raw = try await collect(model, prompt: prompt)
        guard case .answerLocally = ResponseParser.parse(raw) else {
            return XCTFail("synthesis must return prose, not a tool call: \(raw.prefix(80))")
        }
    }

    func testFinalAnswerAfterToolResultPreventsLoop() async throws {
        let model = ScriptedModel()
        let call = ToolCallInfo(name: "calculator", arguments: .object(["expression": .string("12 * 8 + 5")]))
        let messages: [AgentMessage] = [
            .user("calculate 12 * 8 + 5"),
            .toolCall(call),
            .toolResult(content: "12 * 8 + 5 = 101", forCallId: call.id),
        ]
        let raw = try await collect(model, prompt: prompt(for: messages))
        guard case .answerLocally(let answer) = ResponseParser.parse(raw) else {
            return XCTFail("after a tool result the script must give a final answer, got: \(raw.prefix(100))")
        }
        XCTAssertTrue(answer.contains("101"), answer)
    }
}
