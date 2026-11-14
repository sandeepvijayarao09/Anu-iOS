import Foundation

/// Schedules a one-off timer/alarm alert. Injectable so the tool's duration and
/// fire-time logic is testable without actually scheduling anything.
protocol TimerScheduling: Sendable {
    /// Schedule an alert titled `label` to fire at `date`. Returns success.
    func schedule(label: String, at date: Date) async -> Bool
    /// The same, saying whether it's a timer or an alarm, so a scheduler that
    /// can (AlarmKit) rings it as a real alarm. Defaults to `schedule(label:at:)`.
    func schedule(label: String, at date: Date, kind: TimerKind) async -> Bool
}

/// What the user asked for: a countdown or a time of day.
enum TimerKind: String, Sendable {
    case timer, alarm
}

/// A scheduler that can say what it did (protocol extensions dispatch
/// statically, so the tool asks for this one explicitly).
protocol ReportingTimerScheduling: TimerScheduling {
    func scheduleReporting(label: String, at date: Date, kind: TimerKind) async -> ScheduleOutcome
}

/// What a scheduler actually did, so the answer can say it honestly.
enum ScheduleOutcome: Equatable, Sendable {
    /// In the Clock app itself (through the Anu Alarm shortcut).
    case inClock
    /// A real system alarm (AlarmKit): rings through silent mode and Focus.
    case ringing
    /// An AlarmKit alarm where a Clock one was wanted, and why it isn't in Clock.
    case ringingNotInClock(why: String)
    /// A notification only, and why: it won't ring through silent mode.
    case notification(why: String)
    /// Scheduled, by a scheduler that can't say how.
    case scheduled
    case failed(String)
}

extension TimerScheduling {
    func schedule(label: String, at date: Date, kind: TimerKind) async -> Bool {
        await schedule(label: label, at: date)
    }

    func scheduleReporting(label: String, at date: Date, kind: TimerKind) async -> ScheduleOutcome {
        await schedule(label: label, at: date, kind: kind)
            ? .scheduled
            : .failed("Couldn't set the \(kind.rawValue) — notification permission may be off (Settings → Anu).")
    }
}

#if canImport(UserNotifications)
import UserNotifications
/// Fires a local notification at the target time — fully on-device, works
/// offline, no network. Requests notification permission on first use.
struct LocalNotificationScheduler: TimerScheduling {
    func schedule(label: String, at date: Date) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return false }
        let content = UNMutableNotificationContent()
        content.title = label
        content.sound = .default
        let interval = max(1, date.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        do { try await center.add(request); return true } catch { return false }
    }
}
#endif

/// Sets a timer ("in 10 minutes") or an alarm ("tomorrow at 7am") that alerts the
/// user on-device. Works offline; never reaches the network.
struct TimerTool: Tool {
    let name = "set_timer"
    let description = """
    Set a timer or alarm that alerts the user. action 'timer' needs 'duration' \
    ('10 minutes', '90 seconds', '1 hour 30 min'); action 'alarm' needs 'time' \
    (natural language like 'tomorrow at 7am' or '6:30 am'), or 'hour' (0-23) and \
    'minute' for the next time the clock shows it. Optional 'label'.
    """

    let scheduler: any TimerScheduling
    let now: @Sendable () -> Date

    init(scheduler: any TimerScheduling, now: @escaping @Sendable () -> Date = { Date() }) {
        self.scheduler = scheduler
        self.now = now
    }

    var parameters: JSONSchema? {
        .object(
            description: "Timer/alarm parameters",
            properties: [
                "action": .string(description: "timer or alarm", enumValues: ["timer", "alarm"]),
                "duration": .string(description: "For a timer: '10 minutes', '90 seconds', '1 hour'"),
                "time": .string(description: "For an alarm: 'tomorrow at 7am', '6:30 am', '2026-06-30 07:00'"),
                "hour": .integer(description: "For an alarm instead of 'time': hour 0-23, next occurrence"),
                "minute": .integer(description: "Minute 0-59, with 'hour'"),
                "label": .string(description: "Optional label, e.g. 'Tea' or 'Wake up'"),
            ],
            required: ["action"]
        )
    }

    func execute(arguments: JSONValue) async throws -> String {
        let action = (arguments["action"]?.stringValue ?? "").lowercased()
        let label = arguments["label"]?.stringValue ?? (action == "alarm" ? "Alarm" : "Timer")

        let fireDate: Date
        switch action {
        case "timer":
            guard let durationStr = arguments["duration"]?.stringValue,
                  let seconds = ToolDateParsing.parseDuration(durationStr), seconds > 0 else {
                throw ToolError.invalidArgument("duration", expected: "e.g. '10 minutes' or '90 seconds'")
            }
            fireDate = now().addingTimeInterval(seconds)
        case "alarm":
            if let hour = arguments["hour"]?.intValue {
                let minute = arguments["minute"]?.intValue ?? 0
                guard let date = Self.nextOccurrence(hour: hour, minute: minute, after: now()) else {
                    throw ToolError.invalidArgument("hour", expected: "0-23, with minute 0-59")
                }
                fireDate = date
            } else {
                guard let timeStr = arguments["time"]?.stringValue,
                      let date = ToolDateParsing.parse(timeStr, now: now()) else {
                    throw ToolError.invalidArgument("time", expected: "e.g. 'tomorrow at 7am'")
                }
                fireDate = date
            }
        default:
            throw ToolError.invalidArgument("action", expected: "'timer' or 'alarm'")
        }

        let kind: TimerKind = action == "alarm" ? .alarm : .timer
        let set = "Set \(action) \"\(label)\" for \(AnuDate.dateAndTime.string(from: fireDate))."
        let outcome: ScheduleOutcome
        if let reporting = scheduler as? any ReportingTimerScheduling {
            outcome = await reporting.scheduleReporting(label: label, at: fireDate, kind: kind)
        } else {
            outcome = await scheduler.scheduleReporting(label: label, at: fireDate, kind: kind)
        }
        switch outcome {
        case .inClock:
            return set + " It's in the Clock app."
        case .ringing:
            return set + " It rings like a Clock alarm, even on silent."
        case .ringingNotInClock(let why):
            return set + " It's Anu's own alarm: it rings like a Clock alarm, even on silent, but it won't show in the Clock app. \(why)"
        case .notification(let why):
            return set + " It's a notification only, so it won't ring on silent: \(why)"
        case .scheduled:
            return set
        case .failed(let why):
            // Thrown, not returned, so the receipt under the answer says Failed
            // rather than Done (the broker reads a returned string as success).
            throw ToolError.executionFailed(why)
        }
    }

    /// The next time after `now` the clock shows `hour:minute` (today or tomorrow).
    static func nextOccurrence(hour: Int, minute: Int, after now: Date, calendar: Calendar = .current) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                 matchingPolicy: .nextTime)
    }

    /// "7:05 AM" for an hour and minute, in the user's locale.
    static func clockText(hour: Int, minute: Int) -> String {
        var components = DateComponents()
        components.year = 2000
        components.month = 1
        components.day = 1
        components.hour = hour
        components.minute = minute
        guard let date = Calendar.current.date(from: components) else {
            return "\(hour):" + String(format: "%02d", minute)
        }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Broker policy

extension TimerTool {
    func risk(for arguments: JSONValue) -> RiskTier { .writePrivate }
    func describe(_ arguments: JSONValue) -> String {
        let label = ToolDescribing.text(arguments, "label").map { " " + ToolDescribing.quoted($0) } ?? ""
        if ToolDescribing.action(arguments) == "alarm" {
            if let hour = arguments["hour"]?.intValue {
                let minute = arguments["minute"]?.intValue ?? 0
                return "Set an alarm\(label) for \(Self.clockText(hour: hour, minute: minute))"
            }
            return "Set an alarm\(label) for \(ToolDescribing.text(arguments, "time") ?? "the time given")"
        }
        return "Set a timer\(label) for \(ToolDescribing.text(arguments, "duration") ?? "the time given")"
    }
    var editableFields: [EditableField] { [EditableField(key: "label", label: "Label", kind: .line, optional: true)] }
}
