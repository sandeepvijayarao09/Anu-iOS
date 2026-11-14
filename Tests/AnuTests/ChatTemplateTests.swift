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
        let system = GemmaChatTemplate.instructions
        XCTAssertTrue(system.contains("escalate_to_gemini"))
        XCTAssertTrue(system.contains("ReAct"))
    }

    /// The agent prompt must steer everyday actions to the right tools (so the
    /// assistant *does* the task) and tell the model it can pass relative times
    /// like "tomorrow at 5pm" straight through.
    func testSystemPromptGivesEverydayActionGuidance() {
        let system = GemmaChatTemplate.instructions
        XCTAssertTrue(system.contains("reminders tool"))
        XCTAssertTrue(system.contains("calendar tool"))
        XCTAssertTrue(system.contains("contact_action"))
        XCTAssertTrue(system.contains("set_timer"))
        XCTAssertTrue(system.contains("open_app"))
        XCTAssertTrue(system.contains("run_shortcut"))
        XCTAssertTrue(system.lowercased().contains("tomorrow at 5pm"))
    }

    // MARK: - Chat mode template

    func testChatTemplateHasPersonaAndNoToolProtocol() {
        let prompt = GemmaChatTemplate.formatChat(messages: [.user("hey!")])
        XCTAssertTrue(prompt.contains("friendly on-device AI companion"))
        XCTAssertFalse(prompt.contains("tool_call"), "chat turns carry no tool protocol")
        XCTAssertTrue(prompt.hasSuffix("<start_of_turn>model\n"))
    }

    /// Chat and agent turns open the same way, so moving between them keeps
    /// the engine's cached chat instead of re-reading it.
    func testChatAndAgentTurnsShareTheOpening() {
        let history: [AgentMessage] = [.user("hey!"), .assistant("Hi!"), .user("what's 2+2")]
        let chat = GemmaPromptParser.parse(GemmaChatTemplate.formatChat(messages: history))
        let agent = GemmaPromptParser.parse(GemmaChatTemplate.format(messages: history, tools: [CalculatorTool(), WebSearchTool()]))
        XCTAssertEqual(chat[0].content, agent[0].content)
        XCTAssertEqual(chat.count, agent.count)
        XCTAssertTrue(agent.last!.content.contains("**calculator**"), "tools go with the newest message")
        XCTAssertFalse(chat.last!.content.contains("**calculator**"))
    }

    /// Tool steps stay in a chat turn's history too: the same history shape
    /// as an agent turn, and the model knows what was done.
    func testChatTemplateKeepsToolTurns() {
        let call = ToolCallInfo(name: "calculator", arguments: .object([:]))
        let messages: [AgentMessage] = [
            .user("hey"),
            .toolCall(call),
            .toolResult(content: "= 4", forCallId: call.id),
            .assistant("It's 4!"),
            .user("thanks"),
        ]
        let prompt = GemmaChatTemplate.formatChat(messages: messages)
        XCTAssertTrue(prompt.contains("Tool result:\n= 4"))
        XCTAssertTrue(prompt.contains("It's 4!"))
    }

    // MARK: Telling a live conversation only what's new

    private func newestTurn(_ tools: [any Tool], _ message: String) -> String {
        let prompt = GemmaChatTemplate.format(messages: [.user("first"), .assistant("ok"), .user(message)], tools: tools)
        let turns = GemmaPromptParser.parse(prompt)
        return turns[turns.lastIndex { $0.role == .user }!].content
    }

    func testEachToolIsDescribedOncePerConversation() {
        var known: Set<String> = []
        let first = newestTurn([CalculatorTool(), WebSearchTool()], "What's 2+2?")
        XCTAssertEqual(GemmaChatTemplate.describingNewToolsOnly(first, known: &known), first, "the first time, everything")
        XCTAssertEqual(known, ["calculator", "web_search", GemmaChatTemplate.toolCallFormat])

        let again = GemmaChatTemplate.describingNewToolsOnly(newestTurn([WebSearchTool()], "News?"), known: &known)
        XCTAssertTrue(again.contains("Tools for this message (described earlier): web_search."), again)
        XCTAssertFalse(again.contains("Parameters:"))
        XCTAssertFalse(again.contains("To call a tool"))
        XCTAssertTrue(again.hasSuffix("News?"), "the message itself stays")
        XCTAssertLessThan(again.count, first.count / 3)

        let mixed = GemmaChatTemplate.describingNewToolsOnly(newestTurn([CalculatorTool(), DateTimeTool()], "Time?"), known: &known)
        XCTAssertTrue(mixed.contains("- **datetime**"), "a new tool is described")
        XCTAssertFalse(mixed.contains("- **calculator**"))
        XCTAssertTrue(mixed.contains("Also for this message (described earlier): calculator."), mixed)
    }

    func testAMessageWithoutToolsIsLeftAlone() {
        var known: Set<String> = ["calculator"]
        let plain = newestTurn([], "Hello")
        XCTAssertEqual(GemmaChatTemplate.describingNewToolsOnly(plain, known: &known), plain)
    }

    func testMissedTurnsGoWithTheNextMessage() {
        let text = GemmaChatTemplate.withMissedTurns([(true, "What's 15% of 2400?"), (false, "15% of 2400 is 360.")], "Thanks!")
        XCTAssertEqual(text, "Meanwhile, answered without you:\nUser: What's 15% of 2400?\nAnu: 15% of 2400 is 360.\n\nThanks!")
        XCTAssertEqual(GemmaChatTemplate.withMissedTurns([], "Thanks!"), "Thanks!")
    }
}
