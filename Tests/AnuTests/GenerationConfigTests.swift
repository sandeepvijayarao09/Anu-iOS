import XCTest
import AppIntents
@testable import Anu

final class GenerationConfigTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "temperature")
        UserDefaults.standard.removeObject(forKey: "max_tokens")
        super.tearDown()
    }

    func testFromSettingsUsesDefaultsWhenUnset() {
        UserDefaults.standard.removeObject(forKey: "temperature")
        UserDefaults.standard.removeObject(forKey: "max_tokens")
        let config = GenerationConfig.fromSettings
        XCTAssertEqual(config.temperature, GenerationConfig.default.temperature)
        XCTAssertEqual(config.maxNewTokens, GenerationConfig.default.maxNewTokens)
    }

    func testFromSettingsReadsUserValues() {
        UserDefaults.standard.set(0.25, forKey: "temperature")
        UserDefaults.standard.set(128, forKey: "max_tokens")
        let config = GenerationConfig.fromSettings
        XCTAssertEqual(config.temperature, 0.25, accuracy: 0.001)
        XCTAssertEqual(config.maxNewTokens, 128)
    }

    func testStopSequencesIncludeGemmaMarkers() {
        XCTAssertTrue(GenerationConfig.default.stopSequences.contains("<end_of_turn>"))
    }

    func testAgentConfigClampsTemperature() {
        UserDefaults.standard.set(0.9, forKey: "temperature")
        XCTAssertLessThanOrEqual(GenerationConfig.agentFromSettings.temperature, 0.45)
    }

    func testChatConfigIsWarmAndShort() {
        XCTAssertGreaterThan(GenerationConfig.chat.temperature, 0.6, "chat should sample warm")
        XCTAssertLessThanOrEqual(GenerationConfig.chat.maxNewTokens, 256, "chat replies stay short")
    }

    // MARK: - App Intent surface

    func testAskAnuIntentMetadata() {
        XCTAssertTrue(AskAnuIntent.openAppWhenRun, "intent must open the app to show the streamed answer")
        XCTAssertFalse(AnuShortcuts.appShortcuts.isEmpty, "Siri shortcut must be registered")
    }
}
