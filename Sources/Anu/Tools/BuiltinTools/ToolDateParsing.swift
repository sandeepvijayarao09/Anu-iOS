import Foundation

/// Lenient date-string parsing shared by the EventKit-backed tools (reminders,
/// calendar, alarms). Accepts ISO-8601 and common structured formats, **plus the
/// natural-language relative phrasings people actually say to an assistant** —
/// "tomorrow at 5pm", "tonight", "in 10 minutes", "next friday", "this evening".
///
/// Why this matters: the small on-device model is unreliable at converting
/// "tomorrow at 5" into an absolute timestamp (it doesn't reliably know today's
/// date). If the parser only took `2026-06-13 18:00`, those reminders would be
/// created with **no due date**. Parsing the relative form here makes the common
/// case work without leaning on the model's date arithmetic.
enum ToolDateParsing {
    /// `now` is injectable so the relative logic is deterministically testable.
    static func parse(_ raw: String, now: Date = Date()) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // 1) Structured formats (backward compatible — checked first).
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: trimmed) { return d }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss",
                    "yyyy-MM-dd", "MM/dd/yyyy HH:mm", "MM/dd/yyyy", "MMMM d, yyyy h:mm a"] {
            f.dateFormat = fmt
            if let d = f.date(from: trimmed) { return d }
        }

        // 2) Natural-language relative expressions.
        return parseRelative(trimmed.lowercased(), now: now)
    }

    /// Parses a spoken DURATION into seconds: "10 minutes", "90 seconds", "2h",
    /// "1 hour 30 min". Sums every unit it finds; nil if none. Used for timers.
    static func parseDuration(_ raw: String) -> TimeInterval? {
        let s = raw.lowercased()
        guard let re = try? NSRegularExpression(
            pattern: #"(\d+)\s*(seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|s|m|h|d)\b"#
        ) else { return nil }
        var total: TimeInterval = 0
        var found = false
        re.enumerateMatches(in: s, range: NSRange(s.startIndex..., in: s)) { match, _, _ in
            guard let match,
                  let r1 = Range(match.range(at: 1), in: s),
                  let r2 = Range(match.range(at: 2), in: s),
                  let n = Double(s[r1]) else { return }
            let unit = String(s[r2])
            let mult: Double = unit.hasPrefix("h") ? 3600 :
                               (unit.hasPrefix("d") ? 86400 :
                               (unit.hasPrefix("s") ? 1 : 60))   // default: minutes
            total += n * mult
            found = true
        }
        return found ? total : nil
    }

    // MARK: - Relative natural language

    private static let weekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7,
    ]

    private static func parseRelative(_ s: String, now: Date) -> Date? {
        var cal = Calendar.current
        cal.timeZone = .current

        // "in N minutes / hours / days / weeks" — offset straight from now.
        // Accepts word quantities too: "in an hour", "in a couple of hours".
        if let m = regexGroups(s, #"\bin\s+(a|an|a couple of|a couple|a few|\d+)\s*(minutes?|mins?|hours?|hrs?|days?|weeks?)\b"#) {
            let n = wordQuantity(m[1])
            let unit = m[2]
            let comp: Calendar.Component =
                unit.hasPrefix("min") ? .minute :
                (unit.hasPrefix("h") ? .hour :
                (unit.hasPrefix("d") ? .day : .weekOfYear))
            return cal.date(byAdding: comp, value: n, to: now)
        }

        // Resolve the base DAY.
        var baseDay: Date?
        var dayWasExplicit = true
        if s.contains("tomorrow") {
            baseDay = cal.date(byAdding: .day, value: 1, to: now)
        } else if s.contains("yesterday") {
            baseDay = cal.date(byAdding: .day, value: -1, to: now)
        } else if s.contains("next week") {
            baseDay = cal.date(byAdding: .weekOfYear, value: 1, to: now)
        } else if s.contains("weekend") {
            // "this weekend" / "the weekend" → the coming Saturday.
            baseDay = nextWeekday(7, from: now, cal: cal, forceNextWeek: s.contains("next "))
        } else if s.contains("today") || s.contains("tonight") {
            baseDay = now
        } else if let wd = weekdays.first(where: { s.contains($0.key) }) {
            baseDay = nextWeekday(wd.value, from: now, cal: cal, forceNextWeek: s.contains("next "))
        } else {
            baseDay = now
            dayWasExplicit = false  // only a time (or nothing) was given
        }
        guard let day = baseDay else { return nil }

        // Resolve the TIME OF DAY.
        let tod = parseTimeOfDay(s)
        // A bare time with no day implied ("at 5pm") and nothing else relative →
        // require an actual time match, else this isn't a parseable phrase.
        if !dayWasExplicit && tod == nil { return nil }

        // Default time when only a day was given: morning, except "tonight"/
        // "this evening" which clearly mean the evening.
        let (hour, minute): (Int, Int)
        if let tod {
            (hour, minute) = tod
        } else if s.contains("tonight") || s.contains("evening") {
            (hour, minute) = (19, 0)
        } else {
            (hour, minute) = (9, 0)
        }

        guard var combined = cal.date(
            bySettingHour: hour, minute: minute, second: 0, of: day) else { return nil }

        // Time-only and already past today → roll to tomorrow ("remind me at 7"
        // said at 9pm means 7am tomorrow).
        if !dayWasExplicit, combined <= now {
            combined = cal.date(byAdding: .day, value: 1, to: combined) ?? combined
        }
        return combined
    }

    /// Next occurrence of `weekday` (1=Sun…7=Sat). `forceNextWeek` skips a week
    /// when the user said "next friday" and today is before friday.
    private static func nextWeekday(_ weekday: Int, from now: Date, cal: Calendar, forceNextWeek: Bool) -> Date? {
        let today = cal.component(.weekday, from: now)
        var delta = (weekday - today + 7) % 7
        if delta == 0 { delta = 7 }                  // "friday" on a friday → next friday
        if forceNextWeek && delta < 7 { delta += 7 } // "next friday" → skip this week
        return cal.date(byAdding: .day, value: delta, to: now)
    }

    /// Extracts an explicit (hour, minute) from phrasings like "5pm", "at 5:30",
    /// "17:00", "noon", "this afternoon". Returns nil if no time is present.
    /// Maps a small word quantity to an Int: "a"/"an" → 1, "a couple" → 2,
    /// "a few" → 3, otherwise the numeric value (default 1).
    private static func wordQuantity(_ s: String) -> Int {
        switch s {
        case "a", "an": return 1
        case "a couple", "a couple of": return 2
        case "a few": return 3
        default: return Int(s) ?? 1
        }
    }

    private static func parseTimeOfDay(_ s: String) -> (Int, Int)? {
        let eveningCtx = s.contains("tonight") || s.contains("evening") || s.contains("night")
        func pmShift(_ h: Int) -> Int { (eveningCtx && (1...11).contains(h)) ? h + 12 : h }

        // "end of day" / "eod" → 5pm.
        if s.contains("end of day") || s.contains("eod") { return (17, 0) }
        // "half past 3", "quarter past 3", "quarter to 4".
        if let m = regexGroups(s, #"\bhalf past (\d{1,2})\b"#), let h = Int(m[1]), h < 24 {
            return (pmShift(h), 30)
        }
        if let m = regexGroups(s, #"\bquarter past (\d{1,2})\b"#), let h = Int(m[1]), h < 24 {
            return (pmShift(h), 15)
        }
        if let m = regexGroups(s, #"\bquarter to (\d{1,2})\b"#), let h = Int(m[1]), h >= 1, h < 24 {
            return (pmShift(h - 1), 45)
        }

        // Explicit am/pm: "5pm", "5:30 pm", "at 11 am" (most specific first).
        if let m = regexGroups(s, #"(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#) {
            var hour = Int(m[1]) ?? 0
            let minute = m[2].isEmpty ? 0 : (Int(m[2]) ?? 0)
            let pm = m[3] == "pm"
            if hour == 12 { hour = pm ? 12 : 0 } else if pm { hour += 12 }
            if hour < 24 && minute < 60 { return (hour, minute) }
        }
        // 24-hour "17:00" / "at 17:30".
        if let m = regexGroups(s, #"\b(\d{1,2}):(\d{2})\b"#) {
            let hour = Int(m[1]) ?? 0, minute = Int(m[2]) ?? 0
            if hour < 24 && minute < 60 { return (hour, minute) }
        }
        // Bare "at N" — an evening context makes a 1–11 hour PM ("tonight at 9").
        if let m = regexGroups(s, #"\bat\s+(\d{1,2})\b(?!\s*:)"#) {
            var hour = Int(m[1]) ?? 0
            if eveningCtx, (1...11).contains(hour) { hour += 12 }
            if hour < 24 { return (hour, 0) }
        }
        // Coarse parts of day — "afternoon" BEFORE "noon" (afternoon *contains*
        // "noon"), and match "noon" only on a word boundary.
        if s.contains("midnight") { return (0, 0) }
        if s.contains("afternoon") { return (15, 0) }
        if s.contains("morning") { return (9, 0) }
        if s.contains("evening") { return (19, 0) }
        if s.range(of: #"\bnoon\b"#, options: .regularExpression) != nil || s.contains("midday") { return (12, 0) }
        return nil
    }

    /// Returns the full match + capture groups for the first match, or nil.
    /// Group 0 is the whole match; groups 1… are captures ("" if not present).
    private static func regexGroups(_ s: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let match = re.firstMatch(in: s, options: [], range: range) else { return nil }
        return (0..<match.numberOfRanges).map { i in
            guard let r = Range(match.range(at: i), in: s) else { return "" }
            return String(s[r])
        }
    }
}
