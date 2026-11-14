import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

// Daily Brief (Android §1 goals: "AI Daily Brief"; ARCHITECTURE: "schedule,
// email that needs you, follow-ups, commitments" from calendar and memory,
// and the notes, ADR-104). On iOS it is gathered on the phone from today's
// calendar, the reminders due today (and overdue ones), what Anu remembers
// that bears on today, and the newest notes; one on-device model call may
// write it up in a few sentences. Nothing here leaves the phone.
//
// Why a notification and not a brief made at 7 am: iOS gives no guaranteed
// background time at a set hour, and loading the on-device model in a
// background task isn't reliable, so (like scheduled Workflows) the morning
// notification only says the brief is ready to make; it's made when the user
// taps it, in the foreground. It is never an unattended model run.

/// Everything the brief says, gathered on the phone.
struct DailyBrief: Equatable, Sendable {
    struct Event: Equatable, Sendable {
        var title: String
        var start: Date
        var end: Date
        var allDay: Bool
        var location: String?
    }

    struct Reminder: Equatable, Sendable {
        var title: String
        var due: Date?
        var overdue: Bool
    }

    var day: Date
    var events: [Event] = []
    var reminders: [Reminder] = []
    /// What Anu remembers that bears on today, in its own words.
    var remembered: [String] = []
    /// The newest notes' titles.
    var notes: [String] = []
    /// Why a source couldn't be read ("Calendars access not granted…").
    var problems: [String] = []

    var isEmpty: Bool { events.isEmpty && reminders.isEmpty && remembered.isEmpty && notes.isEmpty }

    static let maxEvents = 12
    static let maxReminders = 10
    static let maxRemembered = 3
    static let maxNotes = 3
}

// MARK: - Writing it down (no model)

/// The brief as plain sentences, with no model: what the page shows first and
/// what it falls back to when no on-device model can run.
enum DailyBriefText {
    static func headline(_ brief: DailyBrief, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.wide).month(.wide).day()
        return brief.day.formatted(style)
    }

    static func time(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                        timeZone: calendar.timeZone))
    }

    /// "9:00 AM Standup · Room 4" or "All day Offsite".
    static func line(_ event: DailyBrief.Event, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let when = event.allDay ? "All day" : time(event.start, calendar: calendar, locale: locale)
        let place = event.location.map { " · \($0)" } ?? ""
        return "\(when) \(event.title)\(place)"
    }

    static func line(_ reminder: DailyBrief.Reminder, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if reminder.overdue { return "\(reminder.title) (overdue)" }
        guard let due = reminder.due else { return reminder.title }
        return "\(reminder.title) (\(time(due, calendar: calendar, locale: locale)))"
    }

    /// Two or three sentences: the day's events, the reminders, and the rest.
    static func summary(_ brief: DailyBrief, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var parts: [String] = []
        let timed = brief.events.filter { !$0.allDay }
        switch brief.events.count {
        case 0: parts.append("Nothing is on your calendar today.")
        case 1: parts.append("One thing on your calendar: \(line(brief.events[0], calendar: calendar, locale: locale)).")
        default:
            if let first = timed.first {
                parts.append("\(brief.events.count) things on your calendar, the first at \(time(first.start, calendar: calendar, locale: locale)) (\(first.title)).")
            } else {
                parts.append("\(brief.events.count) all-day things on your calendar.")
            }
        }
        let overdue = brief.reminders.filter(\.overdue).count
        switch (brief.reminders.count, overdue) {
        case (0, _): break
        case (let n, 0): parts.append(n == 1 ? "One reminder is due today." : "\(n) reminders are due today.")
        case (let n, let o): parts.append("\(n) reminder\(n == 1 ? "" : "s") to do, \(o) overdue.")
        }
        if let fact = brief.remembered.first { parts.append("Remember: \(fact).") }
        return parts.joined(separator: " ")
    }

    /// The whole brief as text, for the model and for sharing.
    static func full(_ brief: DailyBrief, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var out = ["Today is \(headline(brief, calendar: calendar, locale: locale))."]
        out.append(brief.events.isEmpty ? "Calendar: nothing today."
                   : "Calendar:\n" + brief.events.map { "- " + line($0, calendar: calendar, locale: locale) }.joined(separator: "\n"))
        if !brief.reminders.isEmpty {
            out.append("Reminders due:\n" + brief.reminders.map { "- " + line($0, calendar: calendar, locale: locale) }.joined(separator: "\n"))
        }
        if !brief.remembered.isEmpty {
            out.append("Remembered about the user:\n" + brief.remembered.map { "- " + $0 }.joined(separator: "\n"))
        }
        if !brief.notes.isEmpty {
            out.append("Newest notes:\n" + brief.notes.map { "- " + $0 }.joined(separator: "\n"))
        }
        return out.joined(separator: "\n\n")
    }
}

// MARK: - Writing it up (one on-device model call)

/// Asks the on-device model to write the brief up. The model sees only the
/// gathered facts, and its answer is used only if it reads like a brief.
enum DailyBriefWriter {
    static let sentinel = "[[DAILY_BRIEF]]"
    static let maxTokens = 220

    static let system = """
    \(sentinel)
    You write the user's morning brief on their phone. Use only the facts given. In two to four short, warm sentences, say what today holds: the first event and anything that needs doing. Don't invent events, times, people or places. No lists, no headings, no questions.
    """

    static func prompt(_ brief: DailyBrief, calendar: Calendar = .current, locale: Locale = .current) -> String {
        GemmaChatTemplate.format(messages: [.user(DailyBriefText.full(brief, calendar: calendar, locale: locale))],
                                 tools: [], systemPromptOverride: system)
    }

    /// The model's answer, cleaned, or nil when it isn't usable (empty, an
    /// engine error, tool-call markup, or far too long).
    static func clean(_ raw: String) -> String? {
        var text = raw
        for marker in ["<end_of_turn>", "<eos>", "<start_of_turn>model"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 900,
              !text.contains("[Generation error"), !text.contains("tool_call"), !text.contains("{\"") else { return nil }
        return text
    }

    /// Writes the brief with `generate`, or nil to fall back to `DailyBriefText.summary`.
    static func write(_ brief: DailyBrief, calendar: Calendar = .current,
                      generate: (String) async throws -> String) async -> String? {
        guard !brief.isEmpty else { return nil }
        guard let raw = try? await generate(prompt(brief, calendar: calendar)) else { return nil }
        return clean(raw)
    }
}

// MARK: - Gathering

/// The calendar and reminders a brief reads. Injectable so tests need no EventKit.
protocol DailyBriefCalendarSource: Sendable {
    func events(on day: Date, calendar: Calendar) async -> Result<[DailyBrief.Event], BriefSourceProblem>
    func reminders(dueBy day: Date, calendar: Calendar) async -> Result<[DailyBrief.Reminder], BriefSourceProblem>
}

struct BriefSourceProblem: Error, Equatable, Sendable {
    let message: String
}

enum DailyBriefGatherer {
    /// What Anu remembers that bears on today: facts that start today, then
    /// facts relevant to today's events. Private (sensitive) facts stay out,
    /// since the brief is read on the screen.
    static func remembered(startingToday facts: [MemoryFact], relevant: [MemoryFact], day: Date,
                           calendar: Calendar = .current) -> [String] {
        let today = facts.filter { fact in
            guard let starts = fact.startsOn else { return false }
            return calendar.isDate(starts, inSameDayAs: day)
        }
        var seen = Set<UUID>()
        var out: [String] = []
        for fact in today + relevant where !fact.sensitive && fact.status != .superseded && seen.insert(fact.id).inserted {
            out.append(fact.text)
            if out.count == DailyBrief.maxRemembered { break }
        }
        return out
    }

    /// Gathers today's brief. `memory` gives the facts that bear on today
    /// from the event titles; `notes` the newest notes' titles.
    static func gather(day: Date, calendar: Calendar = .current, source: any DailyBriefCalendarSource,
                       memory: @MainActor (_ eventTitles: [String]) -> [String],
                       notes: () -> [String]) async -> DailyBrief {
        var brief = DailyBrief(day: day)
        switch await source.events(on: day, calendar: calendar) {
        case .success(let events): brief.events = Array(events.prefix(DailyBrief.maxEvents))
        case .failure(let problem): brief.problems.append(problem.message)
        }
        switch await source.reminders(dueBy: day, calendar: calendar) {
        case .success(let reminders): brief.reminders = Array(reminders.prefix(DailyBrief.maxReminders))
        case .failure(let problem): brief.problems.append(problem.message)
        }
        let titles = brief.events.map(\.title)
        brief.remembered = await MainActor.run { memory(titles) }
        brief.notes = Array(notes().prefix(DailyBrief.maxNotes))
        return brief
    }
}

// MARK: - Schedule

/// When the morning notification comes. Kept in UserDefaults (no personal data).
struct DailyBriefSettings: Equatable, Sendable {
    static let enabledKey = "daily_brief_enabled"
    static let hourKey = "daily_brief_hour"
    static let minuteKey = "daily_brief_minute"

    var enabled: Bool
    var hour: Int
    var minute: Int

    init(enabled: Bool = false, hour: Int = 7, minute: Int = 30) {
        self.enabled = enabled
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    static func load(_ defaults: UserDefaults = .standard) -> DailyBriefSettings {
        DailyBriefSettings(enabled: defaults.bool(forKey: enabledKey),
                           hour: defaults.object(forKey: hourKey) as? Int ?? 7,
                           minute: defaults.object(forKey: minuteKey) as? Int ?? 30)
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(hour, forKey: Self.hourKey)
        defaults.set(minute, forKey: Self.minuteKey)
    }

    var trigger: DateComponents { DateComponents(hour: hour, minute: minute) }
}

/// The slice of the notification center the brief uses; injectable for tests.
protocol DailyBriefNotificationCenter: Sendable {
    func requestAuthorization() async -> Bool
    func removePending(identifiers: [String])
    func add(identifier: String, title: String, body: String, components: DateComponents) async
}

/// Keeps the one repeating morning notification in step with the settings.
enum DailyBriefScheduler {
    static let identifier = "anu.brief.daily"
    static let categoryID = "anu.brief"
    static let userInfoKey = "anuDailyBrief"
    /// The lock screen says only that the brief is ready, never what's in it.
    static let title = "Your daily brief"
    static let body = "Tap to see your day, made on this phone."

    /// Returns false when the brief is on but notifications aren't allowed.
    static func sync(_ settings: DailyBriefSettings, center: any DailyBriefNotificationCenter) async -> Bool {
        center.removePending(identifiers: [identifier])
        guard settings.enabled else { return true }
        guard await center.requestAuthorization() else { return false }
        await center.add(identifier: identifier, title: title, body: body, components: settings.trigger)
        return true
    }

    /// Whether a tapped notification is the brief's.
    static func isBrief(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo[userInfoKey] as? Bool == true
    }
}

#if canImport(UserNotifications)
struct SystemDailyBriefNotificationCenter: DailyBriefNotificationCenter {
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func removePending(identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func add(identifier: String, title: String, body: String, components: DateComponents) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = DailyBriefScheduler.categoryID
        content.userInfo = [DailyBriefScheduler.userInfoKey: true]
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
}
#endif

// MARK: - Opening the brief

/// Asks the app to show the brief: a tapped morning notification or the
/// "Brief me" App Intent. The chat's root view presents it.
@MainActor
final class DailyBriefRouter: ObservableObject {
    static let shared = DailyBriefRouter()
    @Published var pending = false

    func open() { pending = true }
}
