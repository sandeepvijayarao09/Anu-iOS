import XCTest
@testable import Anu

@MainActor
final class TaskClassifierTests: XCTestCase {

    private func type(of text: String) -> TaskType {
        TaskClassifier.shared.classify(text).type
    }

    func testGreetingIsCasualChat() {
        XCTAssertEqual(type(of: "hey, how's it going?"), .casualChat)
    }

    func testArithmeticIsMath() {
        XCTAssertEqual(type(of: "what's 37 * 14 minus 12"), .math)
    }

    func testNewsIsWebInfo() {
        XCTAssertEqual(type(of: "look up today's tech headlines"), .webInfo)
    }

    func testCodingIsCodeGen() {
        XCTAssertEqual(type(of: "write a swift function that reverses a string"), .codeGen)
    }

    func testEssayIsLongWriting() {
        XCTAssertEqual(type(of: "draft a short essay on climate change"), .longWriting)
    }

    func testConfidenceIsBounded() {
        let c = TaskClassifier.shared.classify("hello!").confidence
        XCTAssertGreaterThanOrEqual(c, 0)
        XCTAssertLessThanOrEqual(c, 1.0001)
    }

    func testKeywordFallbackCoversAllTypes() {
        XCTAssertEqual(TaskClassifier.keywordFallback("calculate 5 + 5").type, .math)
        XCTAssertEqual(TaskClassifier.keywordFallback("search the latest news").type, .webInfo)
        XCTAssertEqual(TaskClassifier.keywordFallback("debug my code").type, .codeGen)
        XCTAssertEqual(TaskClassifier.keywordFallback("write an essay").type, .longWriting)
        XCTAssertEqual(TaskClassifier.keywordFallback("explain how engines work").type, .generalQA)
        XCTAssertEqual(TaskClassifier.keywordFallback("hey there").type, .casualChat)
    }

    /// Keyword matching must respect word boundaries: short code tokens like
    /// "api"/"code" must not fire inside ordinary words ("capital"/"barcode").
    func testKeywordFallbackUsesWordBoundaries() {
        XCTAssertEqual(TaskClassifier.keywordFallback("what is the capital of France").type, .generalQA)
        XCTAssertEqual(TaskClassifier.keywordFallback("scan the barcode").type, .casualChat)
        // Genuine code-domain keywords still match as whole words.
        XCTAssertEqual(TaskClassifier.keywordFallback("write a sql query").type, .codeGen)
        XCTAssertEqual(TaskClassifier.keywordFallback("parse this json").type, .codeGen)
    }
}

final class ModelClassifierTests: XCTestCase {

    private func route(
        _ type: TaskType,
        confidence: Double = 0.8,
        cloud: Bool = false,
        webSearch: Bool = false
    ) -> ModelRoute {
        ModelClassifier.route(
            task: TaskClassification(type: type, confidence: confidence),
            cloudAvailable: cloud,
            webSearchAvailable: webSearch
        )
    }

    func testChatStaysOnDevice() {
        XCTAssertEqual(route(.casualChat), .onDeviceChat)
        XCTAssertEqual(route(.generalQA), .onDeviceChat)
    }

    func testMathAlwaysUsesAgentLoop() {
        // The calculator tool needs no key, so math always gets the agent.
        XCTAssertEqual(route(.math), .onDeviceAgent)
        XCTAssertEqual(route(.math, cloud: true, webSearch: true), .onDeviceAgent)
    }

    func testWebInfoUsesAgentOnlyWhenSomethingCanFetch() {
        // A configured search provider or the cloud makes the loop worthwhile…
        XCTAssertEqual(route(.webInfo, webSearch: true), .onDeviceAgent)
        XCTAssertEqual(route(.webInfo, cloud: true), .onDeviceAgent)
        // …but with neither, the loop only spins on a "not configured" tool and
        // degenerates short queries — so answer conversationally instead.
        XCTAssertEqual(route(.webInfo), .onDeviceChat)
    }

    func testHeavyGenerationPrefersCloudWhenAvailable() {
        XCTAssertEqual(route(.codeGen, cloud: true), .cloudEscalate)
        XCTAssertEqual(route(.longWriting, cloud: true), .cloudEscalate)
    }

    func testHeavyGenerationStaysLocalWithoutCloud() {
        XCTAssertEqual(route(.codeGen, cloud: false), .onDeviceChat)
        XCTAssertEqual(route(.longWriting, cloud: false), .onDeviceChat)
    }

    func testLowConfidenceFallsBackToChatNotAgent() {
        // Regression: a short/ambiguous query (e.g. "Tv9 vs ntv") classified
        // with no real signal used to fall through to the tool-heavy ReAct
        // prompt, where the small model degenerated into "Anu: user: …" salad.
        // Uncertain → chat, which degrades gracefully.
        XCTAssertEqual(route(.casualChat, confidence: 0.2), .onDeviceChat)
        XCTAssertEqual(route(.webInfo, confidence: 0.2), .onDeviceChat)
        XCTAssertEqual(route(.codeGen, confidence: 0.1, cloud: true), .onDeviceChat)
    }

    func testNeedsDeviceToolForClockAndCalendarQueries() {
        for q in ["what is the time", "what time is it?", "what's the date today",
                  "remind me to call mom", "what's on my calendar tomorrow"] {
            XCTAssertTrue(ModelClassifier.needsDeviceTool(q), "\(q) should require a device tool")
        }
        for q in ["tell me a joke", "what is the capital of France", "write me a poem"] {
            XCTAssertFalse(ModelClassifier.needsDeviceTool(q), "\(q) should not force the tool path")
        }
    }

    /// Daily-life ACTIONS must reach the tool-capable agent path — messaging,
    /// calling, navigation, music, app-launch, timers, shortcuts, and the
    /// calendar/reminder/contact phrasings the original narrow list missed.
    /// Otherwise the assistant just *talks about* doing it instead of doing it.
    func testNeedsDeviceToolCoversEverydayActions() {
        let actions = [
            // reminders / calendar / contacts (broadened phrasings)
            "add buy milk to my reminders", "schedule a dentist appointment friday at 3pm",
            "am I free tomorrow afternoon", "what's John's phone number", "find Sarah's email address",
            // timers / alarms
            "set a timer for 10 minutes", "set an alarm for 6:30 am", "wake me up at 7",
            // messaging / calling
            "text mom I'll be late", "send a message to Alex", "email my boss the report",
            "call dad", "phone the pharmacy",
            // navigation / local search
            "navigate home", "directions to the airport", "find coffee shops near me",
            // music / app launch / shortcuts
            "play some jazz", "pause the music", "open spotify", "launch instagram",
            "run my morning routine", "start my focus shortcut",
        ]
        for q in actions {
            XCTAssertTrue(ModelClassifier.needsDeviceTool(q), "action '\(q)' should reach the tool path")
        }
    }

    /// Conversational phrasings that merely *contain* an action verb must NOT be
    /// pulled onto the tool path (false-positive guard).
    func testNeedsDeviceToolIgnoresConversational() {
        let chat = [
            "let's play a game of twenty questions", "I'm open to any suggestions",
            "what would you call a baby penguin", "let's start over",
            "do you prefer phone calls or texting", "that was a real call to action",
            "what's a good keyboard shortcut to copy", "I have a packed daily routine",
            "I really love listening to music",
        ]
        for q in chat {
            XCTAssertFalse(ModelClassifier.needsDeviceTool(q), "conversational '\(q)' should stay on chat")
        }
    }
}
