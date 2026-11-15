import XCTest
@testable import Anu

/// Pins the bridge that lets the macOS LiteRT-LM backend drive its native
/// Conversation from Anu's Gemma-templated prompts (parse turns, drop the
/// trailing generation cue, keep the persona inside the first user turn).
final class GemmaPromptParserTests: XCTestCase {

    func testParsesSingleUserTurnAndDropsGenerationCue() {
        let prompt = "<start_of_turn>user\nHello there<end_of_turn>\n<start_of_turn>model\n"
        XCTAssertEqual(GemmaPromptParser.parse(prompt),
                       [GemmaTurn(role: .user, content: "Hello there")])
    }

    func testParsesMultiTurnChat() {
        let prompt = """
        <start_of_turn>user
        Hi<end_of_turn>
        <start_of_turn>model
        Hello!<end_of_turn>
        <start_of_turn>user
        How are you?<end_of_turn>
        <start_of_turn>model
        """
        XCTAssertEqual(GemmaPromptParser.parse(prompt), [
            GemmaTurn(role: .user, content: "Hi"),
            GemmaTurn(role: .model, content: "Hello!"),
            GemmaTurn(role: .user, content: "How are you?"),
        ])
    }

    func testLatestUserTurnIsTheNewestQuery() {
        let prompt = """
        <start_of_turn>user
        first<end_of_turn>
        <start_of_turn>model
        ok<end_of_turn>
        <start_of_turn>user
        second<end_of_turn>
        <start_of_turn>model
        """
        XCTAssertEqual(GemmaPromptParser.latestUserTurn(prompt), "second")
    }

    func testPersonaFoldedIntoFirstUserTurnIsPreserved() {
        // GemmaChatTemplate.formatChat folds the persona into the first user
        // turn as "{persona}\n\n{message}" — it must survive intact.
        let prompt = "<start_of_turn>user\nYou are Anu.\n\nWhat's up?<end_of_turn>\n<start_of_turn>model\n"
        XCTAssertEqual(GemmaPromptParser.parse(prompt).first,
                       GemmaTurn(role: .user, content: "You are Anu.\n\nWhat's up?"))
    }

    func testEmptyAndGarbageYieldNoTurns() {
        XCTAssertEqual(GemmaPromptParser.parse(""), [])
        XCTAssertEqual(GemmaPromptParser.parse("no markers here"), [])
    }
}
