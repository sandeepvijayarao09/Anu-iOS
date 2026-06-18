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
