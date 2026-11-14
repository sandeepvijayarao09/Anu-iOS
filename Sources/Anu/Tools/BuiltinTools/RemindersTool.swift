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
    action 'list' returns open reminders; action 'cancel' deletes the open reminder whose \
    title matches 'title' (asks the user first).
    """

    var parameters: JSONSchema? {
        .object(
            description: "Reminder parameters",
            properties: [
                "action": .string(description: "create, list or cancel", enumValues: ["create", "list", "cancel"]),
                "title": .string(description: "Reminder title (required for create and cancel)"),
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
        guard ["create", "list", "cancel"].contains(action) else {
            throw ToolError.invalidArgument("action", expected: "'create', 'list' or 'cancel'")
        }
        var newTitle: String?
        if action == "create" || action == "cancel" {
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

        case "cancel":
            let predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: nil)
            let reminders: [EKReminder] = await withCheckedContinuation { cont in
                store.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
            }
            // Thrown, so the receipt says Failed instead of Done.
            let index: Int
            switch ReminderMatching.find(newTitle!, in: reminders.map { $0.title ?? "" }) {
            case .found(let i): index = i
            case .none:
                throw ToolError.executionFailed("No open reminder matches \(ToolDescribing.quoted(newTitle!)).")
            case .ambiguous(let titles):
                let names = titles.prefix(5).map { ToolDescribing.quoted($0) }.joined(separator: ", ")
                throw ToolError.executionFailed("More than one reminder matches: \(names). Which one?")
            }
            let reminder = reminders[index]
            let title = reminder.title ?? newTitle!
            do { try store.remove(reminder, commit: true) }
            catch { throw ToolError.executionFailed("Couldn't delete the reminder: \(error.localizedDescription)") }
            return "Cancelled the reminder \(ToolDescribing.quoted(title))."

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

// MARK: - Broker policy

/// Finds the one reminder some words mean (Android's `phone_cancel_reminder`):
/// the exact title, else the one title that starts with the words, else the one
/// that contains them. Two at the same step is ambiguous, so it never guesses.
enum ReminderMatching {
    enum Match: Equatable {
        case found(Int)
        case none
        case ambiguous([String])
    }

    static func find(_ words: String, in titles: [String]) -> Match {
        let wanted = normalize(words)
        guard !wanted.isEmpty else { return .none }
        let normalized = titles.map(normalize)
        let steps: [(String) -> Bool] = [
            { $0 == wanted },
            { $0.hasPrefix(wanted) },
            { $0.contains(wanted) },
        ]
        for step in steps {
            let hits = normalized.indices.filter { step(normalized[$0]) }
            if hits.count == 1 { return .found(hits[0]) }
            if hits.count > 1 { return .ambiguous(hits.map { titles[$0] }) }
        }
        return .none
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .split(separator: " ").joined(separator: " ")
    }
}

extension RemindersTool {
    func risk(for arguments: JSONValue) -> RiskTier {
        switch ToolDescribing.action(arguments) {
        case "create": return .writePrivate
        // Deleting can't be undone from Anu, so it asks every time (ADR-107).
        case "cancel": return .destructive
        default: return .read
        }
    }
    func describe(_ arguments: JSONValue) -> String {
        if ToolDescribing.action(arguments) == "cancel" {
            return "Delete the reminder " + ToolDescribing.quoted(ToolDescribing.text(arguments, "title") ?? "named")
        }
        guard ToolDescribing.action(arguments) == "create" else { return "List your open reminders" }
        var text = "Add the reminder " + ToolDescribing.quoted(ToolDescribing.text(arguments, "title") ?? "untitled")
        if let due = ToolDescribing.text(arguments, "due") { text += ", due \(due)" }
        if let repeats = ToolDescribing.text(arguments, "repeat") { text += ", repeating \(repeats)" }
        return text
    }
    /// Shared lists can be written by other people.
    func returnsUntrustedContent(for arguments: JSONValue) -> Bool {
        ToolDescribing.action(arguments) == "list"
    }
    var editableFields: [EditableField] { [EditableField(key: "title", label: "Title", kind: .line)] }
}
