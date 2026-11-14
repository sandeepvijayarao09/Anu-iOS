import AppIntents
import Foundation

// MARK: - Daily-life action intents (the Siri / Shortcuts "middle layer")
//
// Each intent maps structured parameters straight onto a builtin Tool — NO model
// call — so the action is deterministic, fast, works offline, and reuses the
// tool's natural-language date parsing. Every intent is usable as a Shortcuts
// action; the most common ones are also surfaced for Siri + Spotlight in
// `AnuShortcuts`. The parameter→arguments mapping is a pure static function so it
// is unit-testable without the App Intents runtime or any OS permission.

struct CreateReminderIntent: AppIntent {
    static let title: LocalizedStringResource = "Create a reminder"
    static let description = IntentDescription("Add a reminder, optionally with a due date/time.")
    static let openAppWhenRun = false
    /// `openAppWhenRun` is deprecated from iOS 26; it stays for iOS 17–25.
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Reminder", requestValueDialog: "What should I remind you about?")
    var text: String
    @Parameter(title: "When", requestValueDialog: "When? (say a time, or skip)")
    var when: String?

    /// Pure mapping → `reminders` tool arguments. Testable in isolation.
    static func arguments(text: String, when: String?) -> JSONValue {
        var obj: [String: JSONValue] = ["action": .string("create"), "title": .string(text)]
        if let when, !when.trimmingCharacters(in: .whitespaces).isEmpty {
            obj["due"] = .string(when)
        }
        return .object(obj)
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await RemindersTool().execute(arguments: Self.arguments(text: text, when: when))
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct SetTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set a timer"
    static let description = IntentDescription("Start a timer that alerts you after a duration.")
    static let openAppWhenRun = false
    /// `openAppWhenRun` is deprecated from iOS 26; it stays for iOS 17–25.
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Duration", requestValueDialog: "How long? (e.g. 10 minutes)")
    var duration: String
    @Parameter(title: "Label", requestValueDialog: "Label? (optional)")
    var label: String?

    static func arguments(duration: String, label: String?) -> JSONValue {
        var obj: [String: JSONValue] = ["action": .string("timer"), "duration": .string(duration)]
        if let label, !label.trimmingCharacters(in: .whitespaces).isEmpty {
            obj["label"] = .string(label)
        }
        return .object(obj)
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await TimerTool(scheduler: SystemAlarmScheduler(fallback: LocalNotificationScheduler()))
            .execute(arguments: Self.arguments(duration: duration, label: label))
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct SetAlarmIntent: AppIntent {
    static let title: LocalizedStringResource = "Set an alarm"
    static let description = IntentDescription("Set an alarm for a specific time.")
    static let openAppWhenRun = false
    /// `openAppWhenRun` is deprecated from iOS 26; it stays for iOS 17–25.
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Time", requestValueDialog: "What time? (e.g. tomorrow at 7am)")
    var time: String
    @Parameter(title: "Label", requestValueDialog: "Label? (optional)")
    var label: String?

    static func arguments(time: String, label: String?) -> JSONValue {
        var obj: [String: JSONValue] = ["action": .string("alarm"), "time": .string(time)]
        if let label, !label.trimmingCharacters(in: .whitespaces).isEmpty {
            obj["label"] = .string(label)
        }
        return .object(obj)
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await TimerTool(scheduler: SystemAlarmScheduler(fallback: LocalNotificationScheduler()))
            .execute(arguments: Self.arguments(time: time, label: label))
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}

struct AddCalendarEventIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a calendar event"
    static let description = IntentDescription("Create a calendar event at a given time.")
    static let openAppWhenRun = false
    /// `openAppWhenRun` is deprecated from iOS 26; it stays for iOS 17–25.
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Title", requestValueDialog: "What's the event?")
    var title: String
    @Parameter(title: "Start", requestValueDialog: "When does it start? (e.g. tomorrow at 2pm)")
    var start: String
    @Parameter(title: "End", requestValueDialog: "When does it end? (optional)")
    var end: String?

    static func arguments(title: String, start: String, end: String?) -> JSONValue {
        var obj: [String: JSONValue] = [
            "action": .string("create"), "title": .string(title), "start": .string(start),
        ]
        if let end, !end.trimmingCharacters(in: .whitespaces).isEmpty {
            obj["end"] = .string(end)
        }
        return .object(obj)
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await CalendarTool()
            .execute(arguments: Self.arguments(title: title, start: start, end: end))
        return .result(dialog: IntentDialog(stringLiteral: result))
    }
}
