import XCTest
@testable import Anu

final class StreamParserTests: XCTestCase {

    private func feed(_ parser: SSEParser, _ text: String) async -> [SSEEvent] {
        await parser.process(data: Data(text.utf8))
    }

    func testSingleEvent() async {
        let parser = SSEParser()
        let events = await feed(parser, "data: {\"x\":1}\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "{\"x\":1}")
    }

    func testEventSplitAcrossChunks() async {
        let parser = SSEParser()
        let first = await feed(parser, "data: {\"long\":")
        XCTAssertTrue(first.isEmpty, "incomplete line must stay buffered")
        let second = await feed(parser, "\"value\"}\n\n")
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.data, "{\"long\":\"value\"}")
    }

    func testMultipleEventsInOneChunk() async {
        let parser = SSEParser()
        let events = await feed(parser, "data: one\n\ndata: two\n\n")
        XCTAssertEqual(events.map(\.data), ["one", "two"])
    }

    func testEventTypeAndIdParsed() async {
        let parser = SSEParser()
        let events = await feed(parser, "event: message\nid: 42\ndata: hello\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.type, "message")
        XCTAssertEqual(events.first?.id, "42")
        XCTAssertEqual(events.first?.data, "hello")
    }

    func testFlushReturnsTrailingData() async {
        let parser = SSEParser()
        _ = await feed(parser, "data: trailing-no-newline")
        let flushed = await parser.flush()
        XCTAssertEqual(flushed.first?.data, "trailing-no-newline")
    }
}
