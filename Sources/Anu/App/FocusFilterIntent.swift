import AppIntents
import Foundation

// MARK: - Focus filter
//
// Settings → Focus → (a Focus) → Add Filter → Anu. Two choices per Focus:
//
// - Quiet workflow reminders. Done the system's way: the filter's
//   `appContext` carries a notification predicate, matched against each
//   notification's `filterCriteria`. Workflow reminders are tagged
//   `NotificationFilter.workflowReminder` and are held back; a timer or alarm
//   the user set themselves is never silenced by this.
// - Keep new chats out of memory. Chats started while the Focus is on get
//   their own memory (`MemoryScope.isolated`), so a work Focus doesn't mix
//   work talk into what Anu knows about you, and vice versa.
//
// The system runs `perform()` when the Focus turns on or off (with default
// values when it turns off), and Anu keeps the current choice in
// UserDefaults for the chat code to read.

enum NotificationFilter {
    /// `UNNotificationContent.filterCriteria` of a workflow reminder.
    static let workflowReminder = "anu.workflow-reminder"

    /// What a Focus that quiets reminders lets through: everything that
    /// isn't a workflow reminder.
    static func predicate(quietReminders: Bool) -> NSPredicate? {
        quietReminders ? NSPredicate(format: "SELF != %@", workflowReminder) : nil
    }
}

/// The current Focus's choices. Read by the chat code; written by the filter.
enum FocusSettings {
    static let quietRemindersKey = "focus_quiet_reminders"
    static let isolateNewChatsKey = "focus_isolate_new_chats"

    static func isolateNewChats(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: isolateNewChatsKey)
    }

    /// The memory scope a new chat starts with.
    static func newChatMemoryScope(_ defaults: UserDefaults = .standard) -> MemoryScope {
        isolateNewChats(defaults) ? .isolated : .global
    }

    static func apply(quietReminders: Bool, isolateNewChats: Bool, defaults: UserDefaults = .standard) {
        defaults.set(quietReminders, forKey: quietRemindersKey)
        defaults.set(isolateNewChats, forKey: isolateNewChatsKey)
    }
}

struct AnuFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set Anu Focus Filter"
    static let description: IntentDescription? = IntentDescription(
        "Choose how Anu behaves during this Focus.")

    @Parameter(title: "Quiet workflow reminders", default: true)
    var quietReminders: Bool

    @Parameter(title: "Keep new chats out of memory", default: false)
    var isolateNewChats: Bool

    init() {}
    init(quietReminders: Bool, isolateNewChats: Bool) {
        self.quietReminders = quietReminders
        self.isolateNewChats = isolateNewChats
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Anu", subtitle: "\(Self.summary(quietReminders: quietReminders, isolateNewChats: isolateNewChats))")
    }

    static func summary(quietReminders: Bool, isolateNewChats: Bool) -> String {
        switch (quietReminders, isolateNewChats) {
        case (true, true): return "Reminders quiet · new chats kept out of memory"
        case (true, false): return "Workflow reminders quiet"
        case (false, true): return "New chats kept out of memory"
        case (false, false): return "No changes"
        }
    }

    var appContext: FocusFilterAppContext {
        FocusFilterAppContext(notificationFilterPredicate: NotificationFilter.predicate(quietReminders: quietReminders))
    }

    func perform() async throws -> some IntentResult {
        FocusSettings.apply(quietReminders: quietReminders, isolateNewChats: isolateNewChats)
        return .result()
    }
}
