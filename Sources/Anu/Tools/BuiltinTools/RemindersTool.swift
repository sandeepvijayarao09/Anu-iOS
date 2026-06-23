import Foundation
import EventKit

/// Create or list reminders via EventKit. Requires the user to grant Reminders
/// access (NSRemindersFullAccessUsageDescription). Denied access returns a
/// graceful message — it never crashes or blocks the agent.
struct RemindersTool: Tool {
    let name = "reminders"
    let description = "Manage the user's reminders. action 'create' needs a 'title' (optional 'due' like '2026-06-13 18:00'); action 'list' returns open reminders."

    var parameters: JSONSchema? {
        .object(
            description: "Reminder parameters",
            properties: [
                "action": .string(description: "create or list", enumValues: ["create", "list"]),
                "title": .string(description: "Reminder title (required for create)"),
                "due": .string(description: "Optional due date/time, e.g. '2026-06-13 18:00'"),
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

        let store = EKEventStore()
        let granted: Bool
        do { granted = try await store.requestFullAccessToReminders() }
        catch { return "Couldn't access Reminders: \(error.localizedDescription)" }
        guard granted else {
            return "Reminders access not granted. The user can enable it in Settings → Privacy → Reminders."
        }

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
            do { try store.save(reminder, commit: true) }
            catch { return "Failed to save reminder: \(error.localizedDescription)" }
            return "Reminder created: \"\(newTitle!)\"\(dueNote)"

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
