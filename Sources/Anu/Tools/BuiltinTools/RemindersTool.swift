import Foundation
import EventKit

/// Create or list reminders via EventKit. Requires the user to grant Reminders
/// access (NSRemindersFullAccessUsageDescription). Denied access returns a
/// graceful message — it never crashes or blocks the agent.
struct RemindersTool: Tool {
    let name = "reminders"
    let description = """
    Manage the user's reminders. action 'create' needs a 'title' (optional 'due' — accepts \
    natural language like 'tomorrow at 5pm', 'tonight', 'in 10 minutes', or '2026-06-13 18:00'); \
    action 'list' returns open reminders.
    """

    var parameters: JSONSchema? {
        .object(
            description: "Reminder parameters",
            properties: [
                "action": .string(description: "create or list", enumValues: ["create", "list"]),
                "title": .string(description: "Reminder title (required for create)"),
                "due": .string(description: "Optional due. Natural language ok: 'tomorrow at 5pm', 'tonight', or '2026-06-13 18:00'."),
                "repeat": .string(description: "Optional recurrence: daily, weekdays, weekly, monthly, or yearly"),
            ],
            required: ["action"]
        )
    }

    func execute(arguments: JSONValue) async throws -> String {
        // Validate arguments BEFORE touching the store (keeps the no-permission
        // unit-test paths from triggering a TCC prompt).
        let action = (arguments["action"]?.stringValue ?? "list").lowercased()
        guard action == "create" || action == "list" else {
            throw ToolError.invalidArgument("action", expected: "'create' or 'list'")
        }
        var newTitle: String?
        if action == "create" {
            guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
                throw ToolError.missingArgument("title")
            }
            newTitle = title
        }

        // Same shared store as the calendar — one EventKit store per process,
        // one authorization prompt, and it hears external edits.
        let access = CalendarAccess.shared
        if let problem = await access.ensureReminderAccess() { return problem }
        let store = access.store

        switch action {
        case "create":
            let reminder = EKReminder(eventStore: store)
            reminder.title = newTitle!
            reminder.calendar = store.defaultCalendarForNewReminders()
            var dueNote = ""
            if let dueStr = arguments["due"]?.stringValue, let due = ToolDateParsing.parse(dueStr) {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: due)
                reminder.addAlarm(EKAlarm(absoluteDate: due))
                dueNote = " (due \(dueStr))"
            }
            var repeatNote = ""
            if let rep = arguments["repeat"]?.stringValue, let rule = RecurrenceParsing.rule(from: rep) {
                reminder.addRecurrenceRule(rule)
                repeatNote = ", repeating \(rep.lowercased())"
            }
            do { try store.save(reminder, commit: true) }
            catch { return "Failed to save reminder: \(error.localizedDescription)" }
            return "Reminder created: \"\(newTitle!)\"\(dueNote)\(repeatNote)"

        default: // "list"
            let predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: nil)
            let reminders: [EKReminder] = await withCheckedContinuation { cont in
                store.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
            }
            guard !reminders.isEmpty else { return "No open reminders." }
            let lines = reminders.prefix(10).enumerated().map { i, r in
                "\(i + 1). \(r.title ?? "(untitled)")"
            }
            return "Open reminders:\n" + lines.joined(separator: "\n")
        }
    }
}

/// Maps a natural-language recurrence word to an `EKRecurrenceRule`. Shared by
/// `RemindersTool` and `CalendarTool`. Pure + `nonisolated` so it's unit-testable.
enum RecurrenceParsing {
    static func rule(from text: String) -> EKRecurrenceRule? {
        switch text.lowercased().trimmingCharacters(in: .whitespaces) {
        case "daily", "every day", "each day":
            return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        case "weekly", "every week":
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        case "monthly", "every month":
            return EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        case "yearly", "annually", "every year":
            return EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        case "weekdays", "every weekday", "weekday":
            let weekdays: [EKRecurrenceDayOfWeek] = [
                .init(.monday), .init(.tuesday), .init(.wednesday), .init(.thursday), .init(.friday),
            ]
            return EKRecurrenceRule(
                recurrenceWith: .weekly, interval: 1, daysOfTheWeek: weekdays,
                daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                daysOfTheYear: nil, setPositions: nil, end: nil)
        default:
            return nil
        }
    }
}
