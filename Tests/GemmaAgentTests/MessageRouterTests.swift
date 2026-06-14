import XCTest
@testable import GemmaAgent

final class MessageRouterTests: XCTestCase {

    // MARK: - Chat mode

    func testGreetingsRouteToChat() {
        XCTAssertEqual(MessageRouter.route("Hi"), .chat)
        XCTAssertEqual(MessageRouter.route("hello there!"), .chat)
        XCTAssertEqual(MessageRouter.route("how are you doing today?"), .chat)
        XCTAssertEqual(MessageRouter.route("good morning ☀️"), .chat)
    }

    func testSmallTalkRoutesToChat() {
        XCTAssertEqual(MessageRouter.route("what's your favorite color?"), .chat)
        XCTAssertEqual(MessageRouter.route("tell me something fun"), .chat)
        XCTAssertEqual(MessageRouter.route("I had a rough day"), .chat)
    }

    // MARK: - Agent mode

    func testMathRoutesToAgent() {
        XCTAssertEqual(MessageRouter.route("calculate 12 * 8 + 5"), .agent)
        XCTAssertEqual(MessageRouter.route("what is 15% of 847"), .agent)
        XCTAssertEqual(MessageRouter.route("2+2"), .agent)
    }

    func testSearchRoutesToAgent() {
        XCTAssertEqual(MessageRouter.route("search for the latest AI news"), .agent)
        XCTAssertEqual(MessageRouter.route("what's the weather like"), .agent)
        XCTAssertEqual(MessageRouter.route("look up the current bitcoin price"), .agent)
    }

    func testGenerationTasksRouteToAgent() {
        XCTAssertEqual(MessageRouter.route("write me an essay about space"), .agent)
        XCTAssertEqual(MessageRouter.route("write a python function to sort a list"), .agent)
        XCTAssertEqual(MessageRouter.route("summarize this article for me"), .agent)
        XCTAssertEqual(MessageRouter.route("translate this to spanish"), .agent)
    }

    func testVeryLongMessageRoutesToAgent() {
        let long = String(repeating: "context detail ", count: 25) // > 280 chars
        XCTAssertEqual(MessageRouter.route(long), .agent)
    }
}
