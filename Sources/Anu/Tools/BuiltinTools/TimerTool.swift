import Foundation

/// Schedules a one-off timer/alarm alert. Injectable so the tool's duration and
/// fire-time logic is testable without actually scheduling anything.
protocol TimerScheduling: Sendable {
    /// Schedule an alert titled `label` to fire at `date`. Returns success.
    func schedule(label: String, at date: Date) async -> Bool
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
    (natural language like 'tomorrow at 7am' or '6:30 am'). Optional 'label'.
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
            guard let timeStr = arguments["time"]?.stringValue,
                  let date = ToolDateParsing.parse(timeStr, now: now()) else {
                throw ToolError.invalidArgument("time", expected: "e.g. 'tomorrow at 7am'")
            }
            fireDate = date
        default:
            throw ToolError.invalidArgument("action", expected: "'timer' or 'alarm'")
        }

        let ok = await scheduler.schedule(label: label, at: fireDate)
        let formatter = AnuDate.dateAndTime
        return ok
            ? "Set \(action) \"\(label)\" for \(formatter.string(from: fireDate))."
            : "Couldn't set the \(action) — notification permission may be off (Settings → Notifications)."
    }
}

// MARK: - Broker policy

extension TimerTool {
    func risk(for arguments: JSONValue) -> RiskTier { .writePrivate }
    func describe(_ arguments: JSONValue) -> String {
        let label = ToolDescribing.text(arguments, "label").map { " " + ToolDescribing.quoted($0) } ?? ""
        if ToolDescribing.action(arguments) == "alarm" {
            return "Set an alarm\(label) for \(ToolDescribing.text(arguments, "time") ?? "the time given")"
        }
        return "Set a timer\(label) for \(ToolDescribing.text(arguments, "duration") ?? "the time given")"
    }
    var editableFields: [EditableField] { [EditableField(key: "label", label: "Label", kind: .line, optional: true)] }
}
