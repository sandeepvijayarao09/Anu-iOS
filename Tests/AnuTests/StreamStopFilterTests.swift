import XCTest
@testable import Anu

final class StreamStopFilterTests: XCTestCase {

    private func makeFilter() -> StreamStopFilter {
        StreamStopFilter(stopSequences: ["<end_of_turn>", "<eos>", "<turn|>"])
    }

    func testPlainTextPassesThrough() {
        var f = makeFilter()
        XCTAssertEqual(f.process("Hello world"), "Hello world")
        XCTAssertFalse(f.finished)
    }

    func testStopMarkerInSingleChunk() {
        var f = makeFilter()
        XCTAssertEqual(f.process("Paris<end_of_turn>junk after"), "Paris")
        XCTAssertTrue(f.finished)
    }

    func testStopMarkerSplitAcrossChunks() {
        var f = makeFilter()
        let first = f.process("Paris<end")
        XCTAssertEqual(first, "Paris", "partial marker must be held back")
        XCTAssertFalse(f.finished)
        let second = f.process("_of_turn>more text")
        XCTAssertEqual(second, "", "nothing precedes the completed marker")
        XCTAssertTrue(f.finished)
    }

    func testFalseAlarmPrefixIsReleased() {
        var f = makeFilter()
        XCTAssertEqual(f.process("a<end"), "a")        // "<end" held back
        let out = f.process("less story continues")     // "<endless…" is not a marker
        XCTAssertEqual(out, "<endless story continues")
        XCTAssertFalse(f.finished)
    }

    func testNothingEmittedAfterFinish() {
        var f = makeFilter()
        _ = f.process("done<eos>")
        XCTAssertTrue(f.finished)
        XCTAssertEqual(f.process("late chunk"), "")
    }

    func testAlternateMarkerMatches() {
        var f = makeFilter()
        XCTAssertEqual(f.process("101<turn|>tail"), "101")
        XCTAssertTrue(f.finished)
    }

    func testMarkerSplitOneCharAtATime() {
        var f = makeFilter()
        var emitted = ""
        for ch in "ok<end_of_turn>x" {
            emitted += f.process(String(ch))
            if f.finished { break }
        }
        XCTAssertEqual(emitted, "ok")
        XCTAssertTrue(f.finished)
    }
}
