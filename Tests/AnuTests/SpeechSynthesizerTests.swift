import XCTest
@testable import Anu

@MainActor
final class SpeechSynthesizerTests: XCTestCase {

    func testUtteranceIsNilForBlankText() {
        XCTAssertNil(SpeechSynthesizer.utterance(for: "   \n  "))
        XCTAssertNil(SpeechSynthesizer.utterance(for: ""))
    }

    func testUtteranceBuildsFromTrimmedText() throws {
        let utterance = try XCTUnwrap(SpeechSynthesizer.utterance(for: "  Hello there  "))
        XCTAssertEqual(utterance.speechString, "Hello there")
    }

    func testSpeakIfEnabledRespectsToggleOff() {
        UserDefaults.standard.set(false, forKey: SpeechSynthesizer.enabledKey)
        // Should simply no-op (no crash) when disabled.
        SpeechSynthesizer().speakIfEnabled("this should not be spoken")
    }
}
