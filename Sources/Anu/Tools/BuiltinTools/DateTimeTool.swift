import Foundation

/// On-device clock + simple date math. Zero-permission. The language model has
/// no inherent sense of "now", so this grounds anything time-relative.
struct DateTimeTool: Tool {
    let name = "datetime"
    let description = "Get the current date and time, or compute a date relative to today. Use 'days_offset' for 'in N days'/'N days ago', or 'weekday' (e.g. 'friday') for the next occurrence of that weekday."

    /// Injectable for deterministic tests; nil → real wall clock.
    var referenceDate: Date?
    var calendar: Calendar = .current

    var parameters: JSONSchema? {
        .object(
            description: "Date/time parameters (all optional)",
            properties: [
                "days_offset": .integer(description: "Days from today: 3 = in 3 days, -1 = yesterday"),
                "weekday": .string(description: "A weekday name; returns its next occurrence", enumValues: ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]),
            ]
        )
    }

    func execute(arguments: JSONValue) async throws -> String {
        let now = referenceDate ?? Date()

        let pretty = DateFormatter()
        pretty.calendar = calendar
        pretty.timeZone = calendar.timeZone
        pretty.locale = Locale(identifier: "en_US")
        pretty.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a (zzz)"

        let iso = DateFormatter()
        iso.calendar = calendar
        iso.timeZone = calendar.timeZone
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.dateFormat = "yyyy-MM-dd"

        var lines = ["Now: \(pretty.string(from: now))  (ISO \(iso.string(from: now)))"]

        if let offset = arguments["days_offset"]?.intValue,
           let target = calendar.date(byAdding: .day, value: offset, to: now) {
            let when = offset == 0 ? "today" : (offset > 0 ? "in \(offset) day(s)" : "\(-offset) day(s) ago")
            lines.append("Date \(when): \(weekdayLong(target)), \(iso.string(from: target))")
        }

        if let weekdayName = arguments["weekday"]?.stringValue,
           let target = nextWeekday(weekdayName, after: now) {
            lines.append("Next \(weekdayName.capitalized): \(iso.string(from: target))")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func weekdayLong(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    /// 1 = Sunday … 7 = Saturday (Foundation convention).
    private static let weekdayIndex: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7,
    ]

    private func nextWeekday(_ name: String, after date: Date) -> Date? {
        guard let target = Self.weekdayIndex[name.lowercased().trimmingCharacters(in: .whitespaces)] else {
            return nil
        }
        // Find the next date (strictly after today's weekday) matching `target`.
        let current = calendar.component(.weekday, from: date)
        var delta = target - current
        if delta <= 0 { delta += 7 }
        return calendar.date(byAdding: .day, value: delta, to: date)
    }
}
