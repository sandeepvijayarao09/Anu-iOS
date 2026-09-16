import XCTest
@testable import Anu

final class DateTimeToolTests: XCTestCase {

    private func utc() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = 12
        return utc().date(from: comps)!
    }

    private func iso(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = utc(); f.timeZone = utc().timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    func testCurrentDateAppears() async throws {
        let tool = DateTimeTool(referenceDate: date(2026, 6, 13), calendar: utc())
        let out = try await tool.execute(arguments: .object([:]))
        XCTAssertTrue(out.contains("2026-06-13"), out)
    }

    func testPositiveOffset() async throws {
        let tool = DateTimeTool(referenceDate: date(2026, 6, 13), calendar: utc())
        let out = try await tool.execute(arguments: .object(["days_offset": .int(3)]))
        XCTAssertTrue(out.contains("2026-06-16"), out)
    }

    func testNegativeOffset() async throws {
        let tool = DateTimeTool(referenceDate: date(2026, 6, 13), calendar: utc())
        let out = try await tool.execute(arguments: .object(["days_offset": .int(-1)]))
        XCTAssertTrue(out.contains("2026-06-12"), out)
    }

    func testNextWeekday() async throws {
        let cal = utc()
        let ref = date(2026, 6, 13)
        let tool = DateTimeTool(referenceDate: ref, calendar: cal)
        let out = try await tool.execute(arguments: .object(["weekday": .string("friday")]))

        // Expected: the next Friday strictly after the reference date.
        let current = cal.component(.weekday, from: ref)
        var delta = 6 - current  // 6 == Friday in Foundation's 1=Sun…7=Sat
        if delta <= 0 { delta += 7 }
        let expected = cal.date(byAdding: .day, value: delta, to: ref)!
        XCTAssertTrue(out.contains(iso(expected)), out)
    }
}

/// Natural-language relative date parsing — the phrasings a person says to set a
/// reminder/alarm ("tomorrow at 5pm", "tonight", "in 10 minutes"). `now` is
/// pinned (Mon 2026-06-29 14:00 local) so these are deterministic.
final class ToolDateParsingTests: XCTestCase {
    private var cal: Calendar { var c = Calendar.current; c.timeZone = .current; return c }
    private func now() -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 29; c.hour = 14; c.minute = 0; c.second = 0
        return cal.date(from: c)!
    }
    private func at(_ base: Date, _ h: Int, _ m: Int) -> Date {
        cal.date(bySettingHour: h, minute: m, second: 0, of: base)!
    }
    private func assertParse(_ input: String, equals expected: Date, file: StaticString = #filePath, line: UInt = #line) {
        guard let got = ToolDateParsing.parse(input, now: now()) else {
            return XCTFail("'\(input)' parsed to nil", file: file, line: line)
        }
        XCTAssertEqual(got.timeIntervalSince(expected), 0, accuracy: 60, "'\(input)' → \(got)", file: file, line: line)
    }

    func testRelativeDayAndTime() {
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now())!
        assertParse("tomorrow at 5pm", equals: at(tomorrow, 17, 0))
        assertParse("tomorrow", equals: at(tomorrow, 9, 0))           // day-only → morning
        assertParse("tonight", equals: at(now(), 19, 0))
        assertParse("tonight at 9", equals: at(now(), 21, 0))         // evening ctx → PM
        assertParse("tomorrow afternoon", equals: at(tomorrow, 15, 0)) // not noon!
        assertParse("tomorrow morning", equals: at(tomorrow, 9, 0))
    }

    func testOffsets() {
        assertParse("in 10 minutes", equals: cal.date(byAdding: .minute, value: 10, to: now())!)
        assertParse("in 2 hours", equals: cal.date(byAdding: .hour, value: 2, to: now())!)
        assertParse("in 3 days", equals: cal.date(byAdding: .day, value: 3, to: now())!)
    }

    func testTimeOnlyRollsToTomorrowWhenPast() {
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now())!
        assertParse("at 5pm", equals: at(now(), 17, 0))      // 5pm still ahead of 14:00
        assertParse("at 9am", equals: at(tomorrow, 9, 0))    // 9am already past → tomorrow
        assertParse("noon", equals: at(tomorrow, 12, 0))     // noon past 14:00 → tomorrow
    }

    func testNextWeekday() {
        guard let d = ToolDateParsing.parse("next friday at 3pm", now: now()) else {
            return XCTFail("nil")
        }
        XCTAssertEqual(cal.component(.weekday, from: d), 6)   // Friday
        XCTAssertEqual(cal.component(.hour, from: d), 15)
        XCTAssertGreaterThan(d, now())
    }

    func testBroaderPhrasings() {
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now())!
        assertParse("in an hour", equals: cal.date(byAdding: .hour, value: 1, to: now())!)
        assertParse("in a couple of hours", equals: cal.date(byAdding: .hour, value: 2, to: now())!)
        assertParse("in a few hours", equals: cal.date(byAdding: .hour, value: 3, to: now())!)
        assertParse("end of day", equals: at(now(), 17, 0))
        assertParse("tomorrow at half past 7", equals: at(tomorrow, 7, 30))
        assertParse("tomorrow at quarter to 4", equals: at(tomorrow, 3, 45))
        assertParse("tonight at half past 8", equals: at(now(), 20, 30))   // evening → PM
        // "this weekend" → coming Saturday at 9am (day-only default)
        let we = ToolDateParsing.parse("remind me this weekend", now: now())
        XCTAssertEqual(we.map { cal.component(.weekday, from: $0) }, 7)
    }

    func testStructuredFormatsStillParse() {
        XCTAssertNotNil(ToolDateParsing.parse("2026-07-04 18:00", now: now()))
        XCTAssertNotNil(ToolDateParsing.parse("2026-06-13", now: now()))
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(ToolDateParsing.parse("a few happy thoughts", now: now()))
        XCTAssertNil(ToolDateParsing.parse("", now: now()))
    }

    func testDurationParsing() {
        XCTAssertEqual(ToolDateParsing.parseDuration("10 minutes"), 600)
        XCTAssertEqual(ToolDateParsing.parseDuration("90 seconds"), 90)
        XCTAssertEqual(ToolDateParsing.parseDuration("2h"), 7200)
        XCTAssertEqual(ToolDateParsing.parseDuration("1 hour 30 min"), 5400)
        XCTAssertNil(ToolDateParsing.parseDuration("soon"))
    }
}

/// TimerTool: timer (duration) / alarm (time) → a scheduled fire date. The
/// scheduler is faked so no notification fires; `now` is pinned.
private final class FakeScheduler: TimerScheduling, @unchecked Sendable {
    var scheduled: (label: String, date: Date)?
    var result = true
    func schedule(label: String, at date: Date) async -> Bool {
        scheduled = (label, date); return result
    }
}

final class TimerToolTests: XCTestCase {
    private func now() -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 29; c.hour = 14; c.minute = 0
        var cal = Calendar.current; cal.timeZone = .current
        return cal.date(from: c)!
    }

    func testTimerSchedulesRelativeToNow() async throws {
        let sched = FakeScheduler()
        let tool = TimerTool(scheduler: sched, now: { [n = now()] in n })
        let out = try await tool.execute(arguments: .object([
            "action": .string("timer"), "duration": .string("10 minutes"), "label": .string("Tea"),
        ]))
        XCTAssertEqual(sched.scheduled?.label, "Tea")
        XCTAssertEqual(sched.scheduled?.date.timeIntervalSince(now()) ?? 0, 600, accuracy: 1)
        XCTAssertTrue(out.contains("Tea"))
    }

    func testAlarmUsesNaturalLanguageTime() async throws {
        let sched = FakeScheduler()
        let tool = TimerTool(scheduler: sched, now: { [n = now()] in n })
        _ = try await tool.execute(arguments: .object([
            "action": .string("alarm"), "time": .string("tomorrow at 7am"),
        ]))
        var cal = Calendar.current; cal.timeZone = .current
        let d = try XCTUnwrap(sched.scheduled?.date)
        XCTAssertEqual(cal.component(.hour, from: d), 7)
        XCTAssertEqual(cal.component(.day, from: d), 30)   // tomorrow
    }

    func testBadDurationThrows() async {
        let tool = TimerTool(scheduler: FakeScheduler(), now: { [n = now()] in n })
        do {
            _ = try await tool.execute(arguments: .object([
                "action": .string("timer"), "duration": .string("whenever"),
            ]))
            XCTFail("expected throw")
        } catch { /* expected */ }
    }
}
