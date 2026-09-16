import XCTest
@testable import Anu

/// The daily-life App Intents map their parameters onto builtin-tool arguments.
/// That mapping is a pure function, so we verify it here without the App Intents
/// runtime or any OS permission — the tools themselves are tested separately.
final class DailyActionIntentsTests: XCTestCase {

    private func str(_ v: JSONValue?, _ key: String) -> String? { v?[key]?.stringValue }

    func testReminderMappingWithAndWithoutWhen() {
        let withWhen = CreateReminderIntent.arguments(text: "call mom", when: "tomorrow at 5pm")
        XCTAssertEqual(str(withWhen, "action"), "create")
        XCTAssertEqual(str(withWhen, "title"), "call mom")
        XCTAssertEqual(str(withWhen, "due"), "tomorrow at 5pm")

        let noWhen = CreateReminderIntent.arguments(text: "buy milk", when: nil)
        XCTAssertEqual(str(noWhen, "title"), "buy milk")
        XCTAssertNil(noWhen["due"], "no due key when time omitted")

        let blank = CreateReminderIntent.arguments(text: "x", when: "   ")
        XCTAssertNil(blank["due"], "whitespace-only when is treated as no due")
    }

    func testTimerAndAlarmMapping() {
        let timer = SetTimerIntent.arguments(duration: "10 minutes", label: nil)
        XCTAssertEqual(str(timer, "action"), "timer")
        XCTAssertEqual(str(timer, "duration"), "10 minutes")
        XCTAssertNil(timer["label"])

        let alarm = SetAlarmIntent.arguments(time: "tomorrow at 7am", label: "Wake up")
        XCTAssertEqual(str(alarm, "action"), "alarm")
        XCTAssertEqual(str(alarm, "time"), "tomorrow at 7am")
        XCTAssertEqual(str(alarm, "label"), "Wake up")
    }

    func testCalendarMapping() {
        let ev = AddCalendarEventIntent.arguments(title: "Lunch", start: "tomorrow at noon", end: nil)
        XCTAssertEqual(str(ev, "action"), "create")
        XCTAssertEqual(str(ev, "title"), "Lunch")
        XCTAssertEqual(str(ev, "start"), "tomorrow at noon")
        XCTAssertNil(ev["end"])

        let withEnd = AddCalendarEventIntent.arguments(title: "Mtg", start: "2pm", end: "3pm")
        XCTAssertEqual(str(withEnd, "end"), "3pm")
    }
}
