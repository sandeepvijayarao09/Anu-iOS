import XCTest
@testable import Anu

/// Thousands of generated cases per feature, with fixed seeds so a failure
/// reproduces. The answers are checked against an independent calculation
/// (Measurement, Swift arithmetic), not against Anu's own code.
final class StressTests: XCTestCase {

    /// A small seeded generator (SplitMix64), so runs repeat exactly.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 14))! }
    private func match(_ text: String) -> DirectCommand? { PhoneCommands.match(text, now: now, calendar: calendar) }

    // MARK: Instant commands

    func testThousandsOfTimers() {
        var rng = Seeded(state: 1)
        let templates = ["set a timer for %@", "timer for %@", "start a %@ timer", "set a %@ timer", "Set a timer for %@."]
        var checked = 0
        for _ in 0..<1_200 {
            let n = Int.random(in: 1...59, using: &rng)
            let unit = ["minutes", "seconds", "minute", "min", "mins"].randomElement(using: &rng)!
            let amount = "\(n) \(n == 1 && unit.hasSuffix("s") ? String(unit.dropLast()) : unit)"
            let text = String(format: templates.randomElement(using: &rng)!, amount)
            guard case .tool(let name, let args)? = match(text) else { return XCTFail("no timer for '\(text)'") }
            XCTAssertEqual(name, "set_timer", text)
            XCTAssertEqual(args["action"]?.stringValue, "timer", text)
            checked += 1
        }
        XCTAssertEqual(checked, 1_200)
    }

    func testThousandsOfPercentages() {
        var rng = Seeded(state: 2)
        for _ in 0..<1_500 {
            let rate = Int.random(in: 1...99, using: &rng)
            let cents = Int.random(in: 100...999_999, using: &rng)
            let base = Double(cents) / 100
            let baseText = String(format: "%.2f", base)
            let text = ["what's \(rate)% of \(baseText)", "What is \(rate) percent of \(baseText)?",
                        "\(rate)% of $\(baseText)", "calculate \(rate)% of \(baseText)"].randomElement(using: &rng)!
            guard case .answer(let answer)? = match(text) else { return XCTFail("no answer for '\(text)'") }
            let expected = Double(rate) * base / 100
            let shown = Double(answer.components(separatedBy: " is ").last!.dropLast().replacingOccurrences(of: ",", with: ""))!
            XCTAssertEqual(shown, expected, accuracy: 0.000_001, text)
        }
    }

    func testThousandsOfSums() async throws {
        var rng = Seeded(state: 3)
        let calculator = CalculatorTool()
        for _ in 0..<1_500 {
            let a = Int.random(in: 1...999, using: &rng), b = Int.random(in: 1...999, using: &rng), c = Int.random(in: 1...99, using: &rng)
            let (text, expected): (String, Double) = [
                ("what is \(a) + \(b) * \(c)", Double(a + b * c)),
                ("\(a) - \(b) + \(c)", Double(a - b + c)),
                ("calculate (\(a) + \(b)) x \(c)", Double((a + b) * c)),
                ("\(a) * \(b) / \(c)", Double(a * b) / Double(c)),
            ].randomElement(using: &rng)!
            guard case .tool(let name, let args)? = match(text) else { return XCTFail("no sum for '\(text)'") }
            XCTAssertEqual(name, "calculator", text)
            let out = try await calculator.execute(arguments: args)
            let value = Double(out.components(separatedBy: " = ").last!)!
            XCTAssertEqual(value, expected, accuracy: max(0.001, abs(expected) * 1e-5), "\(text) → \(out)")
        }
    }

    func testThousandsOfConversions() async throws {
        var rng = Seeded(state: 4)
        let pairs: [(String, String, Dimension, Dimension)] = [
            ("miles", "km", UnitLength.miles, UnitLength.kilometers),
            ("km", "miles", UnitLength.kilometers, UnitLength.miles),
            ("kg", "lb", UnitMass.kilograms, UnitMass.pounds),
            ("lb", "kg", UnitMass.pounds, UnitMass.kilograms),
            ("celsius", "fahrenheit", UnitTemperature.celsius, UnitTemperature.fahrenheit),
            ("fahrenheit", "celsius", UnitTemperature.fahrenheit, UnitTemperature.celsius),
            ("feet", "meters", UnitLength.feet, UnitLength.meters),
            ("liters", "gallons", UnitVolume.liters, UnitVolume.gallons),
        ]
        let converter = UnitConverterTool()
        for _ in 0..<1_200 {
            let (from, to, fromUnit, toUnit) = pairs.randomElement(using: &rng)!
            let value = Double(Int.random(in: 1...10_000, using: &rng)) / 10
            let v = String(format: "%g", value)
            let text = ["convert \(v) \(from) to \(to)", "what's \(v) \(from) in \(to)",
                        "how many \(to) is \(v) \(from)", "\(v) \(from) to \(to)"].randomElement(using: &rng)!
            guard case .tool(let name, let args)? = match(text) else { return XCTFail("no conversion for '\(text)'") }
            XCTAssertEqual(name, "unit_converter", text)
            let out = try await converter.execute(arguments: args)
            let shown = Double(out.components(separatedBy: " = ").last!.components(separatedBy: " ").first!)!
            let expected = Measurement(value: value, unit: fromUnit).converted(to: toUnit).value
            XCTAssertEqual(shown, expected, accuracy: abs(expected) * 1e-4 + 1e-6, "\(text) → \(out)")
        }
    }

    /// Ordinary chat must never be taken for a command.
    func testThousandsOfOrdinaryMessagesGoToTheModel() {
        var rng = Seeded(state: 5)
        let openers = ["what is", "tell me about", "can you explain", "why do", "how does", "write a poem about",
                       "what's the best way to", "summarise", "who was", "help me plan"]
        let topics = ["love", "the french revolution", "black holes", "my week", "photosynthesis", "a birthday party",
                      "the capital of peru", "learning swift", "time zones", "an alarm clock's history", "100 years of jazz",
                      "the percent of water in the body", "converting a garage", "timers in cooking"]
        for _ in 0..<1_500 {
            let text = "\(openers.randomElement(using: &rng)!) \(topics.randomElement(using: &rng)!)"
            XCTAssertNil(match(text), "'\(text)' should go to the model")
        }
    }

    // MARK: Tool calls the model writes

    func testThousandsOfToolCallDialects() {
        var rng = Seeded(state: 6)
        let names = ["calculator", "web_search", "set_timer", "reminders", "calendar"]
        for i in 0..<1_500 {
            let name = names.randomElement(using: &rng)!
            let value = "value \(i)"
            let raw: String = [
                #"{"tool_call": {"name": "\#(name)", "arguments": {"q": "\#(value)"}}}"#,
                "Sure.\n```json\n{\"tool_call\": {\"name\": \"\(name)\", \"arguments\": {\"q\": \"\(value)\"}}}\n```",
                #"<|tool_call>call:\#(name){"q":"\#(value)"}<tool_call|>"#,
                #"<|tool_call>call:\#(name){q: "\#(value)"}<tool_call|>"#,
                #"<|tool_call>call:\#(name){q: '\#(value)'}<tool_call|>"#,
            ].randomElement(using: &rng)!
            guard case .callTool(let call) = ResponseParser.parse(raw) else { return XCTFail("missed a call in: \(raw)") }
            XCTAssertEqual(call.name, name, raw)
            XCTAssertEqual(call.arguments["q"]?.stringValue, value, raw)
        }
    }

    // MARK: The chat window

    func testThousandsOfWindows() {
        var rng = Seeded(state: 7)
        for _ in 0..<1_000 {
            var chat: [AgentMessage] = []
            for _ in 0..<Int.random(in: 1...80, using: &rng) {
                let text = String(repeating: "w ", count: Int.random(in: 1...400, using: &rng))
                chat.append(Bool.random(using: &rng) || chat.last?.role != .user ? .user(text) : .assistant(text))
            }
            let budget = Int.random(in: 200...20_000, using: &rng)
            let window = ConversationWindow.windowed(chat, budget: budget)
            XCTAssertEqual(window.last?.id, chat.last?.id, "the newest message is always kept")
            if window.count > 1 {
                XCTAssertEqual(window.first?.role, .user, "a trimmed window opens on a user turn")
                XCTAssertLessThanOrEqual(window.reduce(0) { $0 + $1.content.count }, budget)
            }
            XCTAssertEqual(Array(chat.suffix(window.count)).map(\.id), window.map(\.id), "a window is a suffix of the chat")
        }
    }

    // MARK: Answers people read

    func testThousandsOfAnswersLoseMemoryLabelsOnly() {
        var rng = Seeded(state: 8)
        let words = ["She", "likes", "tea", "and", "toast", "on", "Sundays", "[array]", "x[1]"]
        for _ in 0..<1_000 {
            let plain = (0..<Int.random(in: 1...12, using: &rng)).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ")
            let labelled = plain + " [M\(Int.random(in: 1...30, using: &rng))]."
            XCTAssertEqual(MemoryStore.strippingLabels(labelled), plain + ".")
            XCTAssertEqual(MemoryStore.strippingLabels(plain), plain, "other brackets stay")
        }
    }
}
