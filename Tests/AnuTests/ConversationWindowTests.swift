import XCTest
@testable import Anu

final class ConversationWindowTests: XCTestCase {

    func testShortHistoryUntouched() {
        let messages: [AgentMessage] = [.user("hi"), .assistant("hello!")]
        XCTAssertEqual(ConversationWindow.windowed(messages).count, 2)
    }

    func testLongHistoryDropsOldestFirst() {
        var messages: [AgentMessage] = []
        for i in 0..<40 {
            messages.append(.user("question \(i) " + String(repeating: "x", count: 200)))
            messages.append(.assistant("answer \(i) " + String(repeating: "y", count: 200)))
        }
        let window = ConversationWindow.windowed(messages, budget: 2000)

        XCTAssertLessThan(window.count, messages.count)
        // Most recent message always survives
        XCTAssertEqual(window.last?.content, messages.last?.content)
        // Window respects the budget (approximately — whole turns only)
        let total = window.reduce(0) { $0 + $1.content.count }
        XCTAssertLessThanOrEqual(total, 2000 + 250)
    }

    func testWindowStartsAtUserTurn() {
        var messages: [AgentMessage] = []
        for i in 0..<20 {
            messages.append(.user("q\(i) " + String(repeating: "x", count: 100)))
            messages.append(.assistant("a\(i) " + String(repeating: "y", count: 100)))
        }
        let window = ConversationWindow.windowed(messages, budget: 800)
        XCTAssertEqual(window.first?.role, .user,
                       "window must open with a user turn so the system prompt has a home")
    }

    func testNeverDropsEverything() {
        let messages: [AgentMessage] = [.user(String(repeating: "z", count: 99_999))]
        XCTAssertEqual(ConversationWindow.windowed(messages, budget: 100).count, 1)
    }

    func testWindowStartsAtUserAfterConsecutiveAssistantHead() {
        // Two assistant turns at the head (e.g. a normal reply followed by an
        // "Error generating response" message) used to leave the window opening
        // on an assistant turn, dropping the entire system prompt.
        let messages: [AgentMessage] = [
            .user("old question " + String(repeating: "x", count: 1000)),
            .assistant("old answer " + String(repeating: "y", count: 1000)),
            .assistant("Error generating response " + String(repeating: "z", count: 1000)),
            .user("new question " + String(repeating: "q", count: 100)),
        ]
        let window = ConversationWindow.windowed(messages, budget: 1500)
        XCTAssertEqual(window.first?.role, .user,
                       "window must open on a user turn so the system prompt has a home")
        XCTAssertEqual(window.last?.content, messages.last?.content)
    }
}
