import Foundation

// MARK: - Direct tier (Android parity #17, ADR-076, ADR-099, ADR-107)

/// What a whole phone command becomes, with no model.
enum DirectCommand: Equatable, Sendable {
    /// One tool call. It runs through the broker like any other, so its risk
    /// tier, approvals, receipts and audit all apply.
    case tool(name: String, arguments: JSONValue)
    /// An honest answer for something iOS doesn't let an app do.
    case answer(String)
}

/// Simple phone commands that need no model, ported from Anu for Android's
/// `PhoneCommands`. A message that is exactly one of them becomes one tool
/// call; anything more ("set a timer for ten minutes and email Maya the
/// agenda") returns nil and goes to the model as usual, so nothing is half
/// done. Patterns match whole messages only, and a near miss falls through.
enum PhoneCommands {

    /// iOS has no public API for the volume (ADR-099 on Android).
    static let volumeAnswer = """
        iPhone doesn't let apps change the volume. Use the volume buttons on the side of your iPhone, \
        or the volume slider in Control Center (swipe down from the top-right corner).
        """

    /// iOS has no public API for Do Not Disturb or other Focus modes (ADR-079 on Android).
    static let doNotDisturbAnswer = """
        iPhone doesn't let apps turn Do Not Disturb on or off. Open Control Center (swipe down from \
        the top-right corner), tap Focus, then Do Not Disturb. You can also ask Siri.
        """

    /// The one command `message` is, or nil. `now` and `calendar` place
    /// reminders and alarms; they're parameters so tests are deterministic.
    static func match(_ message: String, now: Date = Date(), calendar: Calendar = .current) -> DirectCommand? {
        // Reminders, places and names keep the user's own capitals; the rest
        // read the words in lower case.
        var said = message.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = said.last, ".!?".contains(last) { said.removeLast() }
        said = said.replacingOccurrences(of: #"^please,? "#, with: "", options: [.regularExpression, .caseInsensitive])
        said = said.replacingOccurrences(of: #",? please$"#, with: "", options: [.regularExpression, .caseInsensitive])
        said = said.trimmingCharacters(in: .whitespaces)
        guard !said.isEmpty, !said.contains("\n") else { return nil }
        let text = said.lowercased()

        let parsers: [() -> DirectCommand?] = [
            { timer(text) },
            { alarm(text, now: now, calendar: calendar) },
            { flashlight(text) },
            { doNotDisturb(text) },
            { brightness(text) },
            { volume(text) },
            { reminder(said, now: now, calendar: calendar) },
            { listReminders(text) },
            { dailyBrief(text) },
            { cancelReminder(said) },
            { call(said) },
            { navigate(said) },
            { openApp(said) },
        ]
        for parse in parsers {
            if let command = parse() { return command }
        }
        return nil
    }

    // MARK: Numbers and units

    /// A day, the longest timer or "in …" reminder.
    private static let maxSeconds = 86_400

    private static let words: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20,
        "twenty-five": 25, "thirty": 30, "forty": 40, "forty-five": 45, "fifty": 50, "sixty": 60, "ninety": 90,
    ]

    private static let number = #"\d{1,5}|"# + words.keys.sorted { $0.count > $1.count }
        .map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
    private static let unit = "seconds?|secs?|minutes?|mins?|hours?|hrs?"
    private static let time = #"(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.?|p\.m\.?)?"#

    private static func value(_ word: String) -> Int? { Int(word) ?? words[word] }

    private static func seconds(per unit: String) -> Int {
        unit.hasPrefix("h") ? 3_600 : unit.hasPrefix("m") ? 60 : 1
    }

    // MARK: Timer and alarm

    private static func timer(_ text: String) -> DirectCommand? {
        let patterns = [
            "^(?:set|start)(?: a| an)? timer (?:for )?(\(number)) (\(unit))$",
            "^(?:set|start)(?: a| an)? (\(number))[ -](\(unit)) timer$",
            "^timer (?:for )?(\(number)) (\(unit))$",
            "^(\(number))[ -](\(unit)) timer$",
        ]
        guard let found = firstMatch(patterns, text), let amount = value(found[1]) else { return nil }
        let per = seconds(per: found[2])
        guard (1...maxSeconds).contains(amount * per) else { return nil }
        let name = per == 3_600 ? "hour" : per == 60 ? "minute" : "second"
        let duration = "\(amount) \(name)\(amount == 1 ? "" : "s")"
        return .tool(name: "set_timer", arguments: .object(["action": .string("timer"), "duration": .string(duration)]))
    }

    /// Day words around an alarm's time: "8 am tomorrow", "tomorrow at 7".
    private static let alarmDay = "today|tonight|this morning|this evening|tomorrow|tomorrow morning|tomorrow evening|in the morning"

    private static func alarm(_ text: String, now: Date, calendar: Calendar) -> DirectCommand? {
        let before = "(?:(\(alarmDay)) (?:at )?)?"
        let after = "(?: (\(alarmDay)))?"
        let patterns = [
            "^(?:set|create)(?: an| a)? alarm (?:for|at) \(before)\(time)\(after)$",
            "^wake me(?: up)? \(before)at \(time)\(after)$",
            "^alarm (?:for|at) \(before)\(time)\(after)$",
        ]
        guard let found = firstMatch(patterns, text), var hour = Int(found[2]) else { return nil }
        let minute = Int(found[3]) ?? 0
        let day = found[1].isEmpty ? found[5] : found[1]
        guard minute <= 59 else { return nil }
        var meridiem = found[4].replacingOccurrences(of: ".", with: "")
        if meridiem.isEmpty, day.hasSuffix("morning") { meridiem = "am" }
        if meridiem.isEmpty, day.hasSuffix("evening") || day == "tonight", (1...11).contains(hour) { meridiem = "pm" }
        switch meridiem {
        case "am":
            guard (1...12).contains(hour) else { return nil }
            if hour == 12 { hour = 0 }
        case "pm":
            guard (1...12).contains(hour) else { return nil }
            if hour != 12 { hour += 12 }
        default:
            guard hour <= 23 else { return nil }
        }
        // No day, or "in the morning": the next time the clock shows it.
        guard !day.isEmpty, day != "in the morning" else {
            return .tool(name: "set_timer", arguments: .object([
                "action": .string("alarm"), "hour": .int(hour), "minute": .int(minute),
            ]))
        }
        let base = day.hasPrefix("tomorrow") ? calendar.date(byAdding: .day, value: 1, to: now) : now
        guard let base, let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base),
              date > now else { return nil }   // "today at 7" when it's past 7: let the model ask
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateFormat = "yyyy-MM-dd HH:mm"
        return .tool(name: "set_timer", arguments: .object([
            "action": .string("alarm"), "time": .string(format.string(from: date)),
        ]))
    }

    // MARK: Flashlight, Do Not Disturb, brightness, volume

    private static func flashlight(_ text: String) -> DirectCommand? {
        let light = "(?:flashlight|flash light|torch)"
        let patterns = [
            "^(?:turn|switch) (on|off) (?:the |my )?\(light)$",
            "^(?:turn|switch) (?:the |my )?\(light) (on|off)$",
            "^\(light) (on|off)$",
        ]
        guard let found = firstMatch(patterns, text) else { return nil }
        return .tool(name: "phone_flashlight", arguments: .object(["on": .bool(found[1] == "on")]))
    }

    private static func doNotDisturb(_ text: String) -> DirectCommand? {
        let dnd = "(?:do not disturb|do-not-disturb|dnd|focus mode)"
        let patterns = [
            "^(?:turn|switch) (?:on|off) \(dnd)$",
            "^(?:turn|switch) \(dnd) (?:on|off)$",
            "^(?:enable|disable|start|stop) \(dnd)$",
            "^\(dnd) (?:on|off)$",
        ]
        return firstMatch(patterns, text) == nil ? nil : .answer(doNotDisturbAnswer)
    }

    /// "40", "40%", "40 percent", or max, min and their kin.
    private static let level = #"(\d{1,3})\s*(?:%|percent)?|max|maximum|full|highest|min|minimum|lowest"#

    private static func percent(_ word: String) -> Int? {
        switch word {
        case "max", "maximum", "full", "highest": return 100
        case "min", "minimum", "lowest": return 0
        default:
            let digits = word.prefix { $0.isNumber }
            guard let value = Int(digits), (0...100).contains(value) else { return nil }
            return value
        }
    }

    private static func brightness(_ text: String) -> DirectCommand? {
        let patterns = [
            "^(?:set|change|turn|put|make)(?: the| my)?(?: screen)? brightness (?:to |at |up to |down to )?(\(level))$",
            "^(?:screen )?brightness (?:to |at )?(\(level))$",
        ]
        guard let found = firstMatch(patterns, text), let value = percent(found[1]) else { return nil }
        return .tool(name: "phone_brightness", arguments: .object(["percent": .int(value)]))
    }

    private static func volume(_ text: String) -> DirectCommand? {
        let stream = "(?:media|music|ring|ringer|ringtone|alarm|notification|notifications) "
        let patterns = [
            "^(?:set|change|turn|put)(?: the| my)? (?:\(stream))?volume (?:to |at |up to |down to )?(?:\(level))$",
            "^(?:\(stream))?volume (?:to |at )?(?:\(level))$",
            "^(?:turn|crank)(?: the| my)? (?:\(stream))?volume (?:up|down)$",
            "^(?:turn|crank) (?:up|down)(?: the| my)? (?:\(stream))?volume$",
            "^volume (?:up|down)$",
            "^(?:mute|unmute)(?: the| my)? (?:phone|volume|sound)$",
        ]
        return firstMatch(patterns, text) == nil ? nil : .answer(volumeAnswer)
    }

    // MARK: Reminders (ADR-107)
    //
    // "remind me at 5 pm to call Mom", "remind me to call Mom tomorrow at 9 am",
    // "remind me in 20 minutes to check the oven". A time with no AM or PM and
    // no day is its next time, either way ("at 5" after noon is 5 PM); with a
    // day ("tomorrow at 9"), it's left to the model.

    private static let maxReminderLength = 200

    private static func reminder(_ said: String, now: Date, calendar: Calendar) -> DirectCommand? {
        guard let rest = groups(#"^(?:remind me|set a reminder|set reminder|create a reminder|add a reminder) (.+)$"#,
                                said, caseInsensitive: true)?[1] else { return nil }
        let ns = rest as NSString
        // The time last: the first place where the rest of the message is exactly a time.
        for split in matches(#" (?=(?:today |tonight |tomorrow )?(?:at|in) )"#, rest) {
            let tail = ns.substring(from: split.range.location + 1).lowercased()
            guard let at = reminderTime(tail, now: now, calendar: calendar) else { continue }
            var task = ns.substring(to: split.range.location)
            task = task.replacingOccurrences(of: #"^(?:to|about|that|for) "#, with: "",
                                             options: [.regularExpression, .caseInsensitive])
            return reminderCall(task, at: at, calendar: calendar)
        }
        // The time first: "at 5 pm to call Mom".
        for split in matches(#",? (?:to|about|that|for) "#, rest) {
            let head = ns.substring(to: split.range.location).lowercased()
            guard let at = reminderTime(head, now: now, calendar: calendar) else { continue }
            return reminderCall(ns.substring(from: split.range.location + split.range.length), at: at, calendar: calendar)
        }
        return nil
    }

    private static func reminderCall(_ task: String, at: Date, calendar: Calendar) -> DirectCommand? {
        let words = task.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty, words.count <= maxReminderLength,
              groups(#"\b(?:and then|then)\b"#, words, caseInsensitive: true, anchored: false) == nil
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return .tool(name: "reminders", arguments: .object([
            "action": .string("create"), "title": .string(words), "due": .string(formatter.string(from: at)),
        ]))
    }

    /// The time `words` name, such as "at 5 pm", "tomorrow at 9:30 am" or "in
    /// 20 minutes", after `now`; else nil.
    static func reminderTime(_ words: String, now: Date, calendar: Calendar) -> Date? {
        let minuteStart = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)) ?? now

        if let found = groups("^in (half an hour|(?:\(number)) (?:\(unit)))$", words) {
            let minutes: Int
            if found[1] == "half an hour" {
                minutes = 30
            } else {
                let parts = found[1].split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2, let count = value(parts[0]) else { return nil }
                switch seconds(per: parts[1]) {
                case 3_600: minutes = count * 60
                case 60: minutes = count
                default: return nil
                }
            }
            guard (1...(maxSeconds / 60)).contains(minutes) else { return nil }
            return minuteStart.addingTimeInterval(TimeInterval(minutes * 60))
        }

        guard let found = groups("^(?:(today|tonight|tomorrow) )?at \(time)(?: (today|tonight|tomorrow))?$", words)
        else { return nil }
        if !found[1].isEmpty, !found[5].isEmpty { return nil }
        let day = found[1].isEmpty ? found[5] : found[1]
        guard var hour = Int(found[2]) else { return nil }
        let minute = Int(found[3]) ?? 0
        guard minute <= 59 else { return nil }

        func next(_ hour: Int) -> Date? {
            guard let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: minuteStart) else { return nil }
            return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
        }

        switch found[4].replacingOccurrences(of: ".", with: "") {
        case "am":
            guard (1...12).contains(hour) else { return nil }
            if hour == 12 { hour = 0 }
        case "pm":
            guard (1...12).contains(hour) else { return nil }
            if hour != 12 { hour += 12 }
        default:
            if hour > 23 { return nil }
            if day == "tonight", (1...11).contains(hour) {
                hour += 12
            } else if (1...12).contains(hour), !found[2].hasPrefix("0") {
                // "At 5": whichever of 5 AM and 5 PM comes next. With a day,
                // it's left to the model. "09:00" is 24-hour.
                guard day.isEmpty, let morning = next(hour % 12), let evening = next(hour % 12 + 12) else { return nil }
                return min(morning, evening)
            }
        }
        guard let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: minuteStart) else { return nil }
        switch day {
        case "today", "tonight": return today > now ? today : nil
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: today)
        default: return next(hour)
        }
    }

    private static func listReminders(_ text: String) -> DirectCommand? {
        let patterns = [
            "^(?:what are|what're|show|show me|list|read)(?: all)? my reminders$",
            "^(?:my|any) reminders$",
            "^do i have any reminders$",
        ]
        guard firstMatch(patterns, text) != nil else { return nil }
        return .tool(name: "reminders", arguments: .object(["action": .string("list")]))
    }

    /// "Brief me", "my daily brief", "what's my day look like": the Daily
    /// Brief, gathered on the phone with no model.
    private static func dailyBrief(_ text: String) -> DirectCommand? {
        let patterns = [
            "^brief me(?: on (?:my |the )?day| for today)?$",
            // A qualifier is required: a lone "brief" is ambiguous.
            "^(?:give me |show me |read me |what's |what is )?(?:(?:my |the |today's )(?:daily |morning )?|(?:daily |morning ))brief(?: for today)?$",
            "^(?:what's|what is|how's|how is) my day(?: today)?(?: look(?:ing)?(?: like)?)?$",
            "^what does my day look like(?: today)?$",
        ]
        guard firstMatch(patterns, text) != nil else { return nil }
        return .tool(name: "daily_brief", arguments: .object([:]))
    }

    private static func cancelReminder(_ said: String) -> DirectCommand? {
        guard let words = groups(#"^(?:cancel|delete|remove|clear) (?:my |the )?reminder (?:to |about |for )?(.+)$"#,
                                 said, caseInsensitive: true)?[1].trimmingCharacters(in: .whitespaces),
              !words.isEmpty else { return nil }
        return .tool(name: "reminders", arguments: .object(["action": .string("cancel"), "title": .string(words)]))
    }

    // MARK: Calls, directions, apps (ADR-107)

    /// Words after "call" that aren't a person: "call me Sam", "call it a day".
    private static let notAPerson: Set<String> = [
        "me", "it", "this", "that", "him", "her", "them", "us", "you", "the", "a", "an", "back", "off", "out",
        "someone", "somebody", "anyone", "everyone", "help",
    ]
    private static let notAName: Set<String> = ["back", "later", "now", "tomorrow", "tonight", "today", "and", "then", "please"]

    /// "call 555-0123" or "call Mom". A name goes to `contact_action`, which
    /// finds the number in Contacts. A call always asks first (writeExternal).
    private static func call(_ said: String) -> DirectCommand? {
        if let number = groups(#"^(?:call|dial|phone|ring) (\+?[\d ().-]{3,20})$"#, said, caseInsensitive: true)?[1]
            .trimmingCharacters(in: .whitespaces), number.filter(\.isNumber).count >= 3 {
            return .tool(name: "contact_action", arguments: .object(["action": .string("call"), "contact": .string(number)]))
        }
        guard var name = groups(#"^(?:call|phone|ring|facetime) (\p{L}[\p{L}'.-]*(?: \p{L}[\p{L}'.-]*){0,2})$"#,
                                said, caseInsensitive: true)?[1] else { return nil }
        let isFaceTime = said.lowercased().hasPrefix("facetime")
        if name.lowercased().hasPrefix("my ") { name.removeFirst(3) }
        let parts = name.lowercased().split(separator: " ").map(String.init)
        guard let first = parts.first, !notAPerson.contains(first),
              !parts.contains(where: notAName.contains) else { return nil }
        return .tool(name: "contact_action", arguments: .object([
            "action": .string(isFaceTime ? "facetime" : "call"), "contact": .string(name),
        ]))
    }

    private static func navigate(_ said: String) -> DirectCommand? {
        let pattern = #"^(?:navigate|(?:get |give me |show me )?directions|take me|drive me|route me|how do i get) to (.+)$"#
        guard let place = groups(pattern, said, caseInsensitive: true)?[1].trimmingCharacters(in: .whitespaces),
              !place.isEmpty, place.count <= 80,
              groups(#"\b(?:and|then)\b"#, place, caseInsensitive: true, anchored: false) == nil
        else { return nil }
        return .tool(name: "phone_navigate", arguments: .object(["destination": .string(place)]))
    }

    /// "Open Spotify". Only apps on `PhoneApps`' list, so "open the door" goes
    /// to the model.
    private static func openApp(_ said: String) -> DirectCommand? {
        guard let name = groups(#"^(?:open|launch|start) (.+)$"#, said, caseInsensitive: true)?[1],
              let app = PhoneApps.find(name) else { return nil }
        return .tool(name: "phone_open_app", arguments: .object(["name": .string(app.name)]))
    }

    // MARK: Regex helpers

    private static func regex(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    /// Group 0 is the whole match; missing groups are "". Nil when no match.
    private static func groups(_ pattern: String, _ text: String,
                               caseInsensitive: Bool = false, anchored: Bool = true) -> [String]? {
        guard let re = regex(pattern, caseInsensitive: caseInsensitive) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        if anchored, m.range.location != 0 || m.range.length != ns.length { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    private static func firstMatch(_ patterns: [String], _ text: String) -> [String]? {
        for pattern in patterns {
            if let found = groups(pattern, text) { return found }
        }
        return nil
    }

    private static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        guard let re = regex(pattern, caseInsensitive: true) else { return [] }
        return re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }
}
