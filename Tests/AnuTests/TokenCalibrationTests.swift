import XCTest
@testable import Anu

final class TokenCalibrationTests: XCTestCase {

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "calibration-\(UUID().uuidString)")!
    }

    func testRawEstimatesUseSeparateRates() {
        let prose = String(repeating: "a", count: 350)
        XCTAssertEqual(TokenCalibration.rawEstimate(prose, kind: .prose), 100)
        XCTAssertEqual(TokenCalibration.rawEstimate(prose, kind: .json), 140)
        XCTAssertEqual(TokenCalibration.rawEstimate("", kind: .prose), 0)
        XCTAssertEqual(TokenCalibration.rawEstimate("abcd", kind: .prose), 2, "rounded up")
    }

    func testSplitSeparatesJSONLinesFromProse() {
        let text = """
        You are Anu, a helpful assistant.
        {"tool_call": {"name": "calculator", "arguments": {"expression": "2+2"}}}
          "name": "web_search",
        ]
        Answer in one paragraph.
        """
        let parts = TokenCalibration.split(text)
        XCTAssertEqual(parts.prose, "You are Anu, a helpful assistant.\nAnswer in one paragraph.")
        XCTAssertTrue(parts.json.contains("tool_call"))
        XCTAssertTrue(parts.json.contains("web_search"))
        XCTAssertTrue(parts.json.hasSuffix("]"))
    }

    func testUncalibratedScaleIsOne() {
        let calibration = TokenCalibration(defaults: nil)
        XCTAssertNil(calibration.ratio(for: .prose))
        XCTAssertEqual(calibration.scale(for: .prose), 1.0)
        XCTAssertEqual(calibration.estimate(String(repeating: "a", count: 700), kind: .prose), 200)
    }

    func testFirstSampleSetsRatioThenSmooths() {
        let calibration = TokenCalibration(defaults: nil)
        calibration.observe(TokenSample(kind: .prose, estimated: 400, counted: 480))
        XCTAssertEqual(calibration.ratio(for: .prose) ?? 0, 1.2, accuracy: 1e-9)
        calibration.observe(TokenSample(kind: .prose, estimated: 400, counted: 400))
        XCTAssertEqual(calibration.ratio(for: .prose) ?? 0, 1.2 + 0.3 * (1.0 - 1.2), accuracy: 1e-9)
        XCTAssertNil(calibration.ratio(for: .json), "each kind learns on its own")
        XCTAssertEqual(calibration.scale(for: .prose), (calibration.ratio(for: .prose) ?? 0) * TokenCalibration.margin, accuracy: 1e-9)
    }

    func testSmallAndEmptySamplesAreIgnoredAndRatiosClamped() {
        let calibration = TokenCalibration(defaults: nil)
        calibration.observe(TokenSample(kind: .json, estimated: 50, counted: 100))
        calibration.observe(TokenSample(kind: .json, estimated: 400, counted: 0))
        XCTAssertNil(calibration.ratio(for: .json))
        calibration.observe(TokenSample(kind: .json, estimated: 200, counted: 5000))
        XCTAssertEqual(calibration.ratio(for: .json), TokenCalibration.maxRatio)
    }

    func testRatiosPersistAcrossLaunches() {
        let defaults = suite()
        let first = TokenCalibration(defaults: defaults)
        first.observe(TokenSample(kind: .prose, estimated: 1000, counted: 800))
        first.observe(TokenSample(kind: .json, estimated: 1000, counted: 1300))

        let relaunched = TokenCalibration(defaults: defaults)
        XCTAssertEqual(relaunched.ratio(for: .prose) ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(relaunched.ratio(for: .json) ?? 0, 1.3, accuracy: 1e-9)

        relaunched.reset()
        XCTAssertNil(TokenCalibration(defaults: defaults).ratio(for: .prose))
    }

    func testLearnUsesTheModelsOwnCountsPerKind() async {
        let calibration = TokenCalibration(defaults: nil)
        // The model's tokenizer makes one token of every 5 characters, so
        // prose (raw 3.5) learns 0.7 and JSON (raw 2.5) learns 0.5.
        let model = MeteredMockModel([], charsPerToken: 5)
        let prose = String(repeating: "word ", count: 300)
        let json = (0..<60).map { #"{"name": "tool_\#($0)", "arguments": {}}"# }.joined(separator: "\n")
        await calibration.learn(from: prose + "\n" + json, model: model)
        XCTAssertEqual(calibration.ratio(for: .prose) ?? 0, 0.7, accuracy: 0.01)
        XCTAssertEqual(calibration.ratio(for: .json) ?? 0, 0.5, accuracy: 0.01)
    }

    func testLearnDoesNothingWithoutATokenizer() async {
        let calibration = TokenCalibration(defaults: nil)
        await calibration.learn(from: String(repeating: "word ", count: 500), model: ScriptedModel())
        XCTAssertNil(calibration.ratio(for: .prose))
    }

    // MARK: - The context budget uses the calibrated rate

    private func history() -> [AgentMessage] {
        (0..<20).flatMap { i -> [AgentMessage] in
            [.user("question \(i) " + String(repeating: "x", count: 200)),
             .assistant("answer \(i) " + String(repeating: "y", count: 200))]
        }
    }

    func testWindowShrinksWhenTheModelCountsMoreTokens() {
        let messages = history()
        let raw = TokenCalibration(defaults: nil)
        let dense = TokenCalibration(defaults: nil)
        dense.observe(TokenSample(kind: .prose, estimated: 1000, counted: 2000))

        let rawWindow = ConversationWindow.windowed(messages, tokenBudget: 800, calibration: raw)
        let denseWindow = ConversationWindow.windowed(messages, tokenBudget: 800, calibration: dense)
        XCTAssertLessThan(denseWindow.count, rawWindow.count)
        XCTAssertEqual(denseWindow.last?.content, messages.last?.content)
        XCTAssertEqual(denseWindow.first?.role, .user)
        let used = denseWindow.reduce(0) { $0 + dense.estimate($1.content, kind: .prose) }
        XCTAssertLessThanOrEqual(used, 800)
    }

    func testToolMessagesAreBudgetedAsJSON() {
        let calibration = TokenCalibration(defaults: nil)
        let result = AgentMessage.toolResult(content: String(repeating: "z", count: 250), forCallId: "1")
        XCTAssertEqual(TokenCalibration.kind(of: result), .json)
        XCTAssertEqual(TokenCalibration.kind(of: .user("hi")), .prose)
        let window = ConversationWindow.windowed([.user("q"), result], tokenBudget: 50, calibration: calibration)
        XCTAssertEqual(window.count, 1, "250 chars of JSON is 100 tokens, over the budget")
    }

    func testUncalibratedDefaultWindowMatchesTheOldCharacterBudget() {
        let messages = history()
        let byTokens = ConversationWindow.windowed(messages, tokenBudget: ConversationWindow.defaultTokenBudget,
                                                   calibration: TokenCalibration(defaults: nil))
        let byChars = ConversationWindow.windowed(messages, budget: ConversationWindow.defaultBudget)
        XCTAssertLessThanOrEqual(abs(byTokens.count - byChars.count), 2)
    }

    /// The chat kept grows with the model's room (the user asked for the most
    /// each chat can hold), and never shrinks below the old lean window.
    func testHistoryFillsTheModelsContext() {
        XCTAssertEqual(ConversationWindow.historyBudget(contextTokens: 4_096), ConversationWindow.defaultTokenBudget)
        XCTAssertEqual(ConversationWindow.historyBudget(contextTokens: 8_192), 8_192 - ConversationWindow.reservedTokens)
        XCTAssertEqual(ConversationWindow.historyBudget(contextTokens: 32_768), 32_768 - ConversationWindow.reservedTokens)
        XCTAssertGreaterThanOrEqual(LiteRTLMModel.contextTokens, LiteRTLMModel.fallbackContextTokens)
        XCTAssertEqual(ScriptedModel().contextTokens, 4_096, "backends that can't say keep the conservative default")
    }

    func testALongChatIsKeptWholeOnALargeModel() {
        let long = (0..<200).flatMap { i in [AgentMessage.user("question \(i) " + String(repeating: "word ", count: 30)),
                                             AgentMessage.assistant("answer \(i) " + String(repeating: "word ", count: 30))] }
        let small = ConversationWindow.windowed(long, tokenBudget: ConversationWindow.historyBudget(contextTokens: 4_096), calibration: TokenCalibration(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        let large = ConversationWindow.windowed(long, tokenBudget: ConversationWindow.historyBudget(contextTokens: 32_768), calibration: TokenCalibration(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        XCTAssertLessThan(small.count, 20)
        XCTAssertGreaterThan(large.count, small.count * 10)
        XCTAssertEqual(large.first?.role, .user)
    }

    /// A full chat's window keeps the same opening for many turns, so the
    /// engine can keep reading on instead of starting over each message.
    func testTheWindowsOpeningStaysPutAsTheChatGrows() {
        var chat: [AgentMessage] = []
        var openings: [UUID] = []
        for i in 0..<120 {
            chat.append(.user("question \(i) " + String(repeating: "word ", count: 40)))
            chat.append(.assistant("answer \(i) " + String(repeating: "word ", count: 40)))
            if let first = ConversationWindow.windowed(chat, budget: 6_000).first?.id { openings.append(first) }
        }
        let moves = zip(openings, openings.dropFirst()).filter { $0 != $1 }.count
        // Each turn here is a sixth of a step, so the opening moves about
        // every three turns once full (it would move on every one of ~108).
        XCTAssertLessThanOrEqual(moves, 40, "the opening moved \(moves) times in 120 turns")
        let last = ConversationWindow.windowed(chat, budget: 6_000)
        XCTAssertLessThanOrEqual(last.reduce(0) { $0 + $1.content.count }, 6_000)
        XCTAssertEqual(last.first?.role, .user)
    }

    /// Tools and memory go with the newest message; the first turn stays the same.
    func testPerMessageContextGoesWithTheNewestMessage() {
        let first = AgentMessage.user("hello"), reply = AgentMessage.assistant("hi"), now = AgentMessage.user("set a timer")
        let prompt = GemmaChatTemplate.format(messages: [first, reply, now], tools: [CalculatorTool()], memoryContext: "MEMORY-BLOCK")
        let turns = GemmaPromptParser.parse(prompt)
        XCTAssertFalse(turns[0].content.contains("MEMORY-BLOCK"))
        XCTAssertFalse(turns[0].content.contains("**calculator**"))
        XCTAssertTrue(turns.last!.content.contains("MEMORY-BLOCK"))
        XCTAssertTrue(turns.last!.content.contains("**calculator**"))
        XCTAssertTrue(turns.last!.content.hasSuffix(GemmaChatTemplate.messageHeader + "set a timer"))
        // The first message's opening, context removed, is the opening later turns see.
        let firstOnly = GemmaPromptParser.parse(GemmaChatTemplate.format(messages: [first], tools: [CalculatorTool()], memoryContext: "M"))
        XCTAssertEqual(GemmaChatTemplate.withoutTurnContext(firstOnly[0].content), turns[0].content)
        let later = GemmaChatTemplate.format(messages: [first, reply, now, .assistant("done"), .user("thanks")],
                                             tools: [CalculatorTool()], memoryContext: "OTHER-MEMORY")
        XCTAssertEqual(GemmaPromptParser.parse(later)[0].content, turns[0].content, "the opening is unchanged")
    }
}
