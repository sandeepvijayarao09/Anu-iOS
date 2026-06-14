import XCTest
@testable import GemmaAgent

final class PIISanitizerTests: XCTestCase {

    func testEmailRedacted() {
        let r = PIISanitizer.sanitize("email me at john.doe@example.com please")
        XCTAssertEqual(r.text, "email me at [EMAIL] please")
        XCTAssertEqual(r.redactions, 1)
    }

    func testPhoneRedacted() {
        let r = PIISanitizer.sanitize("call me at 617-555-0123 tomorrow")
        XCTAssertTrue(r.text.contains("[PHONE]"), r.text)
        XCTAssertFalse(r.text.contains("617-555-0123"))
    }

    func testSSNRedacted() {
        let r = PIISanitizer.sanitize("my ssn is 123-45-6789")
        XCTAssertTrue(r.text.contains("[ID]"))
        XCTAssertFalse(r.text.contains("123-45-6789"))
    }

    func testCardNumberRedacted() {
        let r = PIISanitizer.sanitize("card 4111 1111 1111 1111 expires soon")
        XCTAssertTrue(r.text.contains("[NUMBER]"), r.text)
        XCTAssertFalse(r.text.contains("4111"))
    }

    func testMultipleRedactionsCounted() {
        let r = PIISanitizer.sanitize("a@b.com and c@d.org")
        XCTAssertEqual(r.redactions, 2)
    }

    func testCleanTextUntouched() {
        let input = "write me an essay about space exploration"
        let r = PIISanitizer.sanitize(input)
        XCTAssertEqual(r.text, input)
        XCTAssertEqual(r.redactions, 0)
    }
}

final class ConversationStoreTests: XCTestCase {
    private var dir: URL!
    private var store: ConversationStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ConversationStore(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRoundTrip() {
        let messages: [AgentMessage] = [.user("hi"), .assistant("hello!"), .system("note")]
        let history: [AgentMessage] = [.user("hi"), .assistant("hello!")]
        store.save(messages: messages, history: history)

        let loaded = store.load()
        XCTAssertEqual(loaded?.messages.count, 3)
        XCTAssertEqual(loaded?.history.count, 2)
        XCTAssertEqual(loaded?.messages.first?.content, "hi")
        XCTAssertEqual(loaded?.messages.first?.role, .user)
    }

    func testToolMessagesSurvive() {
        let call = ToolCallInfo(name: "calculator", arguments: .object(["expression": .string("2+2")]))
        let messages: [AgentMessage] = [.toolCall(call), .toolResult(content: "= 4", forCallId: call.id)]
        store.save(messages: messages, history: messages)

        let loaded = store.load()
        XCTAssertEqual(loaded?.messages.first?.toolCall?.name, "calculator")
        XCTAssertEqual(loaded?.messages.last?.toolResultFor, call.id)
    }

    func testClearRemovesFile() {
        store.save(messages: [.user("x")], history: [])
        store.clear()
        XCTAssertNil(store.load())
    }

    func testLoadWithoutSaveIsNil() {
        XCTAssertNil(store.load())
    }
}
