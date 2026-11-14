import XCTest
@testable import Anu

/// Gemma 4 ignores the prompt's JSON tool-call contract often enough that the
/// parser has to accept its native syntax too. These pin that fallback without
/// loosening the documented JSON path.
final class NativeToolCallParsingTests: XCTestCase {

    // MARK: - The exact output that used to leak into the chat

    func testParsesGemmaNativeCallSyntax() throws {
        let raw = #"<|tool_call>call:calculator{"expression":"0.18 * 47.50"}<tool_call|>"#
        let call = try XCTUnwrap(ResponseParser.extractToolCall(from: raw))
        XCTAssertEqual(call.name, "calculator")
        XCTAssertEqual(call.arguments, .object(["expression": .string("0.18 * 47.50")]))
    }

    func testNativeCallRoutesToToolNotAnswer() throws {
        let raw = #"<|tool_call>call:calculator{"expression":"2+2"}<tool_call|>"#
        guard case .callTool(let call) = ResponseParser.parse(raw) else {
            return XCTFail("native syntax must route to a tool, not render as an answer")
        }
        XCTAssertEqual(call.name, "calculator")
    }

    // MARK: - Marker and shape variants

    func testToleratesMarkerVariantsAndMissingCloser() throws {
        for raw in [
            #"<tool_call>call:date_time{"query":"now"}</tool_call>"#,
            #"<|tool_call|>date_time{"query":"now"}"#,
            #"<|tool_call>call:date_time{"query":"now"}"#,
        ] {
            let call = try XCTUnwrap(ResponseParser.extractToolCall(from: raw), raw)
            XCTAssertEqual(call.name, "date_time", raw)
        }
    }

    func testBracesInsideArgumentStringsDoNotTruncate() throws {
        let raw = #"<|tool_call>call:read_text{"text":"a } brace"}<tool_call|>"#
        let call = try XCTUnwrap(ResponseParser.extractToolCall(from: raw))
        XCTAssertEqual(call.arguments, .object(["text": .string("a } brace")]))
    }

    func testProseAroundTheCallIsIgnored() throws {
        let raw = #"Sure, let me work that out. <|tool_call>call:calculator{"expression":"1+1"}<tool_call|> one moment"#
        let call = try XCTUnwrap(ResponseParser.extractToolCall(from: raw))
        XCTAssertEqual(call.name, "calculator")
    }

    // MARK: - The documented JSON form still wins, and non-calls stay answers

    func testDocumentedJSONFormStillParses() throws {
        let raw = #"{"tool_call": {"name": "calculator", "arguments": {"expression": "3*3"}}}"#
        let call = try XCTUnwrap(ResponseParser.extractToolCall(from: raw))
        XCTAssertEqual(call.name, "calculator")
    }

    func testPlainProseIsNotMistakenForACall() {
        XCTAssertNil(ResponseParser.extractToolCall(from: "The answer is 8.55."))
        XCTAssertNil(ResponseParser.extractToolCall(from: "I could use a tool_call here."))
    }

    func testMalformedNativeCallDoesNotCrashOrInvent() {
        // No argument object, and an unbalanced tail — both must decline.
        XCTAssertNil(ResponseParser.extractToolCall(from: "<|tool_call>call:calculator<tool_call|>"))
        XCTAssertNil(ResponseParser.extractToolCall(from: #"<|tool_call>call:calculator{"expression":"#))
    }

    // MARK: - Loose (JavaScript-style) argument objects
    //
    // The model alternates between strict JSON and JS object literals between
    // runs. The first fix only handled quoted keys, so a bare-key call still
    // leaked into the chat; these pin both shapes.

    func testParsesBareKeyArguments() throws {
        let raw = #"<|tool_call>call:calculator{expression: "0.18 * 47.50"}<tool_call|>"#
        let call = try XCTUnwrap(ResponseParser.extractToolCall(from: raw))
        XCTAssertEqual(call.name, "calculator")
        XCTAssertEqual(call.arguments, .object(["expression": .string("0.18 * 47.50")]))
    }

    func testParsesSingleQuotedArguments() throws {
        let raw = "<|tool_call>call:calculator{expression: '0.18 * 47.50'}<tool_call|>"
        let call = try XCTUnwrap(ResponseParser.extractToolCall(from: raw))
        XCTAssertEqual(call.arguments, .object(["expression": .string("0.18 * 47.50")]))
    }

    func testBareKeyCallRoutesToTool() throws {
        let raw = #"<|tool_call>call:calculator{expression: "2+2"}<tool_call|>"#
        guard case .callTool(let call) = ResponseParser.parse(raw) else {
            return XCTFail("bare-key arguments must still route to a tool")
        }
        XCTAssertEqual(call.name, "calculator")
    }

    func testRepairLeavesValidJSONByteIdentical() {
        let valid = #"{"expression":"a: b","n":2,"ok":true,"nil":null}"#
        XCTAssertEqual(ResponseParser.repairLooseJSON(valid), valid)
    }

    func testRepairDoesNotTouchColonsOrKeywordsInsideStrings() throws {
        let raw = #"<|tool_call>call:read_text{text: "ratio 3:1, true, null"}<tool_call|>"#
        let call = try XCTUnwrap(ResponseParser.extractToolCall(from: raw))
        XCTAssertEqual(call.arguments, .object(["text": .string("ratio 3:1, true, null")]))
    }

    func testRepairKeepsLiteralsUnquoted() throws {
        let raw = #"<|tool_call>call:timer{seconds: 30, repeats: false, label: null}<tool_call|>"#
        let call = try XCTUnwrap(ResponseParser.extractToolCall(from: raw))
        XCTAssertEqual(call.arguments,
                       .object(["seconds": .int(30), "repeats": .bool(false), "label": .null]))
    }

    func testLooseInnerKeysInDocumentedFormStillParse() throws {
        // Quoted outer key (so the strict path engages) but loose inner ones.
        let raw = #"{"tool_call": {name: "calculator", arguments: {expression: "1+1"}}}"#
        let call = try XCTUnwrap(ResponseParser.extractToolCall(from: raw))
        XCTAssertEqual(call.name, "calculator")
    }
}
