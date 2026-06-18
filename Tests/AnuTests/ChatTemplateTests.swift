import XCTest
@testable import Anu

final class ChatTemplateTests: XCTestCase {

    func testFormatEndsWithOpenModelTurn() {
        let prompt = GemmaChatTemplate.format(messages: [.user("hi")], tools: [])
        XCTAssertTrue(prompt.hasSuffix("<start_of_turn>model\n"))
    }

    func testUserMessageIsWrappedInTurnMarkers() {
        let prompt = GemmaChatTemplate.format(messages: [.user("what is 2+2")], tools: [])
        // System prompt is folded into the first user turn (Gemma has no system role)
        XCTAssertTrue(prompt.contains("<start_of_turn>user\n"))
        XCTAssertTrue(prompt.contains("what is 2+2<end_of_turn>"))
        XCTAssertFalse(prompt.contains("<start_of_turn>system"))
    }

    func testToolDescriptionsAppearInSystemPrompt() {
        let prompt = GemmaChatTemplate.format(messages: [.user("hi")], tools: [CalculatorTool()])
        XCTAssertTrue(prompt.contains("calculator"))
        XCTAssertTrue(prompt.contains("tool_call"))
    }

    func testToolResultComesBackAsUserTurn() {
        let call = ToolCallInfo(name: "calculator", arguments: .object([:]))
        let messages: [AgentMessage] = [
            .user("calc"),
            .toolResult(content: "= 4", forCallId: call.id),
        ]
        let prompt = GemmaChatTemplate.format(messages: messages, tools: [])
        XCTAssertTrue(prompt.contains("<start_of_turn>user\nTool result:\n= 4<end_of_turn>"))
    }

    func testSystemPromptListsEscalationGuidance() {
        let system = GemmaChatTemplate.buildSystemPrompt(tools: [])
        XCTAssertTrue(system.contains("escalate_to_gemini"))
        XCTAssertTrue(system.contains("ReAct"))
    }

    // MARK: - Chat mode template

    func testChatTemplateHasPersonaAndNoToolProtocol() {
        let prompt = GemmaChatTemplate.formatChat(messages: [.user("hey!")])
        XCTAssertTrue(prompt.contains("friendly on-device AI companion"))
        XCTAssertFalse(prompt.contains("tool_call"), "chat mode must not carry the tool protocol")
        XCTAssertFalse(prompt.contains("ReAct"))
        XCTAssertTrue(prompt.hasSuffix("<start_of_turn>model\n"))
    }

    func testChatTemplateIsMuchShorterThanAgentTemplate() {
        let chat = GemmaChatTemplate.formatChat(messages: [.user("hey!")])
        let agent = GemmaChatTemplate.format(messages: [.user("hey!")], tools: [CalculatorTool(), WebSearchTool()])
        XCTAssertLessThan(chat.count, agent.count / 2, "chat prefill should be substantially smaller")
    }

    func testChatTemplateSkipsToolTurns() {
        let call = ToolCallInfo(name: "calculator", arguments: .object([:]))
        let messages: [AgentMessage] = [
            .user("hey"),
            .toolCall(call),
            .toolResult(content: "= 4", forCallId: call.id),
            .assistant("It's 4!"),
        ]
        let prompt = GemmaChatTemplate.formatChat(messages: messages)
        XCTAssertFalse(prompt.contains("Tool result"))
        XCTAssertTrue(prompt.contains("It's 4!"))
    }
}
