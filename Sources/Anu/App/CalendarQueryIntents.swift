import AppIntents
import EventKit

// MARK: - Calendar read intents
//
// The existing calendar intent only *writes* (`AddCalendarEventIntent`), so
// "Hey Siri, what's on my calendar" had no route into Anu. These are the read
// side. They answer from the shared `CalendarAccess` store, so an event added
// in Calendar.app moments earlier is already reflected.
//
// Both return `ProvidesDialog` so Siri speaks the answer without launching the
// app — the point of asking by voice is not to end up looking at a screen.

struct TodaysScheduleIntent: AppIntent {
    static let title: LocalizedStringResource = "What's on my calendar today"
    static let description = IntentDescription(
        "Reads the rest of today's events straight from your calendar.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let access = CalendarAccess.shared
        if let problem = await access.ensureEventAccess() {
            return .result(dialog: IntentDialog(stringLiteral: problem))
        }
        let events = access.eventsRemainingToday()
        return .result(dialog: IntentDialog(stringLiteral: Self.spoken(for: events)))
    }

    /// Phrased for speech, not for a screen: a count first so the listener
    /// knows how much is coming, then the items.
    static func spoken(for events: [EKEvent]) -> String {
        guard let first = events.first else {
            return "Nothing left on your calendar today."
        }
        if events.count == 1 {
            return "One thing left today: \(first.anuSummary)."
        }
        let listed = events.prefix(5).map(\.anuSummary).joined(separator: ", ")
        let more = events.count > 5 ? ", and \(events.count - 5) more" : ""
        return "\(events.count) things left today: \(listed)\(more)."
    }
}

struct NextEventIntent: AppIntent {
    static let title: LocalizedStringResource = "What's my next event"
    static let description = IntentDescription(
        "Reads the next event on your calendar, however far out it is.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let access = CalendarAccess.shared
        if let problem = await access.ensureEventAccess() {
            return .result(dialog: IntentDialog(stringLiteral: problem))
        }
        // A month is far enough to answer honestly without scanning forever.
        let horizon = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
        let next = access.events(from: Date(), to: horizon).first
        return .result(dialog: IntentDialog(stringLiteral: Self.spoken(for: next)))
    }

    static func spoken(for event: EKEvent?) -> String {
        guard let event else { return "Nothing on your calendar for the next month." }
        let when = Calendar.current.isDateInToday(event.startDate)
            ? "today at \(event.anuTimeOnly)"
            : AnuDate.spoken.string(from: event.startDate)
        return "Next up: \(event.title ?? "an untitled event"), \(when)."
    }
}

extension EKEvent {
    var anuTimeOnly: String { AnuDate.time.string(from: startDate) }
}
