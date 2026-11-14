import Foundation

/// When a workflow repeats. Pure value type: it knows its calendar triggers and
/// its next fire date, and nothing about notifications, so the widget can
/// compile it and tests can check it without scheduling anything.
struct WorkflowSchedule: Codable, Sendable, Equatable, Hashable {
    enum Repeat: String, Codable, Sendable, CaseIterable, Identifiable {
        case daily, weekdays, weekly
        var id: String { rawValue }

        var label: String {
            switch self {
            case .daily: return "Every day"
            case .weekdays: return "Weekdays"
            case .weekly: return "Every week"
            }
        }
    }

    var repeats: Repeat
    var hour: Int
    var minute: Int
    /// `Calendar` weekday (1 = Sunday … 7 = Saturday). Used only by `.weekly`.
    var weekday: Int

    init(repeats: Repeat = .daily, hour: Int = 8, minute: Int = 0, weekday: Int = 2) {
        self.repeats = repeats
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.weekday = min(max(weekday, 1), 7)
    }

    /// One repeating calendar trigger per component set: a single one for daily
    /// and weekly, one per weekday (Mon–Fri) for `.weekdays`.
    var triggerComponents: [DateComponents] {
        switch repeats {
        case .daily:
            return [DateComponents(hour: hour, minute: minute)]
        case .weekdays:
            return (2...6).map { DateComponents(hour: hour, minute: minute, weekday: $0) }
        case .weekly:
            return [DateComponents(hour: hour, minute: minute, weekday: weekday)]
        }
    }

    /// The earliest time strictly after `date` that this schedule fires.
    func nextFireDate(after date: Date, calendar: Calendar = .current) -> Date? {
        triggerComponents
            .compactMap { calendar.nextDate(after: date, matching: $0, matchingPolicy: .nextTime) }
            .min()
    }

    /// "Weekdays at 8:00 AM", "Mondays at 6:30 PM".
    func summary(calendar: Calendar = .current, locale: Locale = .current) -> String {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        // Format in the calendar's own zone, or the hour shifts by the offset.
        let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                     calendar: calendar, timeZone: calendar.timeZone)
        let time = calendar.date(from: comps).map { $0.formatted(style) }
            ?? String(format: "%02d:%02d", hour, minute)
        switch repeats {
        case .daily: return "Every day at \(time)"
        case .weekdays: return "Weekdays at \(time)"
        case .weekly:
            var cal = calendar
            cal.locale = locale
            let name = cal.weekdaySymbols[weekday - 1]
            return "\(name)s at \(time)"
        }
    }
}
