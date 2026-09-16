import XCTest
import EventKit
@testable import Anu

/// REAL end-to-end integration against the simulator's EventKit store — not a
/// mock. Drives the actual `RemindersTool` / `CalendarTool`, then verifies the
/// item truly landed by reading it back through EventKit, and cleans up.
///
/// Permission-gated: if the run can't get EventKit access (e.g. no
/// `simctl privacy grant`), the test `XCTSkip`s instead of failing, so the suite
/// stays stable. Grant access before running with, e.g.:
///   xcrun simctl privacy booted grant reminders com.anu.app
///   xcrun simctl privacy booted grant calendar  com.anu.app
final class EventKitIntegrationTests: XCTestCase {

    func testReminderIsActuallyCreatedAndListedBack() async throws {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        try XCTSkipUnless(granted, "Reminders access unavailable — skipping real EventKit integration test.")

        let marker = "AnuIT-\(UUID().uuidString.prefix(8))"
        defer { removeReminders(titled: marker, in: store) }

        // Create through the real tool (real EventKit write).
        let createOut = try await RemindersTool().execute(arguments: .object([
            "action": .string("create"),
            "title": .string(marker),
            "due": .string("tomorrow at 9am"),
        ]))
        XCTAssertTrue(createOut.contains(marker), "create should confirm the title — got: \(createOut)")

        // List back through the real tool — proves it persisted to the store.
        let listOut = try await RemindersTool().execute(arguments: .object(["action": .string("list")]))
        XCTAssertTrue(listOut.contains(marker), "created reminder should appear in list — got: \(listOut)")

        // And confirm directly via EventKit (independent of the tool).
        let found = try await fetchReminders(in: store).contains { $0.title == marker }
        XCTAssertTrue(found, "reminder should be readable straight from EventKit")
    }

    func testCalendarEventIsActuallyCreated() async throws {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        try XCTSkipUnless(granted, "Calendar access unavailable — skipping real EventKit integration test.")
        try XCTSkipUnless(store.defaultCalendarForNewEvents != nil,
                          "No writable calendar in this environment — skipping.")

        let marker = "AnuIT-\(UUID().uuidString.prefix(8))"
        defer { removeEvents(titled: marker, in: store) }

        let createOut = try await CalendarTool().execute(arguments: .object([
            "action": .string("create"),
            "title": .string(marker),
            "start": .string("tomorrow at 2pm"),
        ]))
        XCTAssertTrue(createOut.contains(marker), "create should confirm the title — got: \(createOut)")
    }

    func testRecurrenceParsingMapsWords() {
        XCTAssertEqual(RecurrenceParsing.rule(from: "daily")?.frequency, .daily)
        XCTAssertEqual(RecurrenceParsing.rule(from: "every week")?.frequency, .weekly)
        XCTAssertEqual(RecurrenceParsing.rule(from: "monthly")?.frequency, .monthly)
        XCTAssertEqual(RecurrenceParsing.rule(from: "yearly")?.frequency, .yearly)
        let weekdays = RecurrenceParsing.rule(from: "weekdays")
        XCTAssertEqual(weekdays?.frequency, .weekly)
        XCTAssertEqual(weekdays?.daysOfTheWeek?.count, 5, "Mon–Fri")
        XCTAssertNil(RecurrenceParsing.rule(from: "sometimes"), "unknown → nil")
    }

    func testRecurringReminderPersistsWithRule() async throws {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        try XCTSkipUnless(granted, "Reminders access unavailable — skipping.")

        let marker = "AnuIT-\(UUID().uuidString.prefix(8))"
        defer { removeReminders(titled: marker, in: store) }

        let out = try await RemindersTool().execute(arguments: .object([
            "action": .string("create"), "title": .string(marker),
            "due": .string("tomorrow at 9am"), "repeat": .string("daily"),
        ]))
        XCTAssertTrue(out.contains("repeating daily"), "tool should confirm recurrence — got: \(out)")

        let created = try await fetchReminders(in: store).first { $0.title == marker }
        XCTAssertEqual(created?.recurrenceRules?.first?.frequency, .daily,
                       "the persisted reminder should carry a daily recurrence rule")
    }

    // MARK: - Helpers

    private func fetchReminders(in store: EKEventStore) async throws -> [EKReminder] {
        let pred = store.predicateForReminders(in: nil)
        return await withCheckedContinuation { cont in
            store.fetchReminders(matching: pred) { cont.resume(returning: $0 ?? []) }
        }
    }

    private func removeReminders(titled marker: String, in store: EKEventStore) {
        let pred = store.predicateForReminders(in: nil)
        store.fetchReminders(matching: pred) { reminders in
            for r in (reminders ?? []) where r.title == marker {
                try? store.remove(r, commit: true)
            }
        }
    }

    private func removeEvents(titled marker: String, in store: EKEventStore) {
        let start = Date().addingTimeInterval(-86_400)
        let end = Date().addingTimeInterval(7 * 86_400)
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        for e in store.events(matching: pred) where e.title == marker {
            try? store.remove(e, span: .thisEvent, commit: true)
        }
    }
}
