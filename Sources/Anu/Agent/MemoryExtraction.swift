import CryptoKit
import Foundation

// Memory v2, steps 1–2 of the pipeline (Android `core:memory`, ARCHITECTURE
// §8.2, §8.5): what may be kept (I1), how facts are compared, when a dated
// fact comes true (ADR-147), and the on-device extractor (P6, ADR-123).
// Everything here is pure and deterministic so it is unit-tested directly.

// MARK: - What memory may keep (I1)

enum MemoryFilters {
    /// Messages about credentials are never kept or learned from, even on the phone.
    private static let credential = #"\b(passwords?|passcodes?|passphrases?|pin (code|number|is)|api keys?|secret keys?|access tokens?|one[- ]time (code|password)|verification code|security code|otp)\b"#

    /// A one-time code in the message ("your code is 482913").
    private static let oneTimeCode = #"\b(code|otp)\b[^0-9]{0,20}\b\d{4,8}\b"#

    /// Learning is limited to messages where the user talks about themself or
    /// people in their life. Requests like "Book lunch with Maya" hold no
    /// lasting fact, and skipping them saves a model call each.
    private static let aboutSomeone = #"\b(i|i'm|im|i've|i'll|i'd|my|me|mine|myself|we|we're|our|us)\b"#

    static let minChars = 8

    /// The text to store for a chat message, or nil if it shouldn't be kept or learned from.
    static func forChat(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minChars, trimmed.memoryMatches(aboutSomeone) else { return nil }
        return cleaned(trimmed)
    }

    /// The text to store for something the user said directly, or nil if it holds a secret.
    /// Card, bank and ID numbers are cut; nothing else is changed.
    static func cleaned(_ text: String) -> String? {
        if text.memoryMatches(credential) || text.memoryMatches(oneTimeCode) { return nil }
        var out = text
        out = out.memoryReplacing(#"\b\d{3}-\d{2}-\d{4}\b"#, with: "[ID]")
        out = out.memoryReplacing(#"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}(?: ?[A-Z0-9]{1,3})?\b"#, with: "[IBAN]", caseInsensitive: false)
        out = out.memoryReplacing(#"(?<!\d)\d(?:[ -]?\d){12,18}(?!\d)"#, with: "[NUMBER]")
        return out
    }

    /// A fact may be kept only if it carries no credential, code, or card, bank
    /// or ID number. Underscores read as spaces, so `wifi_password` is caught too.
    static func safeToKeep(_ text: String) -> Bool {
        let plain = text.replacingOccurrences(of: "_", with: " ")
        guard let cleaned = cleaned(plain) else { return false }
        return cleaned == plain
    }
}

// MARK: - Comparing facts

enum MemoryNormalize {
    private static let selfWords: Set<String> = ["i", "me", "my", "mine", "myself", "user", "the user", "you", "yourself", "the user's"]

    static func subject(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return selfWords.contains(trimmed.lowercased()) ? MemoryFact.user : trimmed
    }

    static func predicate(_ raw: String) -> String {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        p = p.memoryReplacing(#"[\s-]+"#, with: "_")
        p = p.memoryReplacing(#"[^a-z0-9_]"#, with: "")
        p = p.memoryReplacing(#"_+"#, with: "_")
        p = p.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return canonical[p] ?? p
    }

    /// One word for each relation (Android ADR-144), so a one-at-a-time
    /// relation is replaced whatever word the model chose.
    private static let canonical: [String: String] = {
        var map: [String: String] = [:]
        func to(_ canonical: String, _ words: [String]) { words.forEach { map[$0] = canonical } }
        to("lives_in", ["residence", "resides_in", "location", "current_location", "current_city", "city", "home_city", "home", "lives", "lives_at", "based_in", "located_in",
                        "move", "moves_to", "moved_to", "moving_to", "moving", "relocating_to", "relocated_to", "relocation", "new_city", "new_home"])
        to("works_at", ["workplace", "employer", "company", "works_for", "employed_at", "employed_by", "job_at", "organization", "workplace_name"])
        to("job_title", ["job", "occupation", "profession", "role", "position", "title"])
        to("likes", ["hobby", "hobbies", "enjoys", "interest", "interests", "likes_to", "loves", "passion"])
        to("dislikes", ["hates", "doesnt_like"])
        to("birthday", ["birth_date", "date_of_birth", "born_on", "dob"])
        to("diet", ["dietary_preference", "dietary_restriction"])
        to("partner", ["spouse", "wife", "husband", "girlfriend", "boyfriend", "significant_other"])
        to("allergic_to", ["allergy", "allergies", "allergic"])
        to("manager", ["boss", "supervisor"])
        return map
    }()

    /// Relations a person has one of at a time. A new value replaces the old one.
    static let singleValued: Set<String> = ["name", "age", "birthday", "pronouns", "works_at", "job_title", "manager", "lives_in", "hometown", "timezone", "diet", "partner"]

    static func value(_ raw: String) -> String { words(raw).joined(separator: " ") }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { !$0.isEmpty }
    }

    /// A deleted fact is remembered only as this hash, never as text (§8.4).
    static func fingerprint(subject: String, predicate: String, value: String) -> String {
        let key = "\(self.subject(subject).lowercased())|\(self.predicate(predicate))|\(self.value(value))"
        return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Dated facts (ADR-147)

/// When a fact comes true, if it hasn't yet. "I'm moving to Denver next month"
/// isn't where the user lives today: it is kept as upcoming and replaces the
/// old city on its day. The day comes from the words first (rules, because a
/// small model's date arithmetic is what it gets wrong), then from the date
/// the model wrote, and a change told in the future tense with no day counts
/// from 30 days on. Only a change starts on a day: in "Maya's birthday is in
/// June" the day is the fact.
enum UpcomingDay {
    static let undatedDays = 30

    static func start(starts: String?, quote: String, today: Date, message: String? = nil, calendar: Calendar = .current) -> Date? {
        let day = calendar.startOfDay(for: today)
        let words = (quote + " " + sentence(of: quote, in: message ?? quote)).lowercased()
        guard words.memoryMatches(change) else { return nil }
        let found = fromWords(words, today: day, calendar: calendar)
            ?? starts.flatMap { s -> Date? in
                let t = s.trimmingCharacters(in: .whitespaces)
                return fromModel(t, calendar: calendar) ?? fromWords(t.lowercased(), today: day, calendar: calendar)
            }
            ?? ((words.memoryMatches(future) && !words.memoryMatches(past)) ? calendar.date(byAdding: .day, value: undatedDays, to: day) : nil)
        guard let found, found > day else { return nil }
        return calendar.startOfDay(for: found)
    }

    /// The sentence of `message` that holds every word of `quote`, or "".
    private static func sentence(of quote: String, in message: String) -> String {
        let wanted = Set(MemoryNormalize.words(quote))
        guard !wanted.isEmpty else { return "" }
        let sentences = message.memoryReplacing(#"(?<=[.!?;])\s+|\n"#, with: "\u{1}").components(separatedBy: "\u{1}")
        return sentences.first { wanted.isSubset(of: Set(MemoryNormalize.words($0))) } ?? ""
    }

    private static func fromWords(_ text: String, today: Date, calendar: Calendar) -> Date? {
        if text.memoryMatches(past) { return nil }
        if text.memoryMatches(#"\btomorrow\b"#) { return calendar.date(byAdding: .day, value: 1, to: today) }
        if text.memoryMatches(#"\bnext week\b"#) { return next(weekday: 2, after: today, calendar: calendar) }
        if text.memoryMatches(#"\bnext month\b"#) {
            let month = calendar.date(byAdding: .month, value: 1, to: today)!
            return calendar.date(from: calendar.dateComponents([.year, .month], from: month))
        }
        if text.memoryMatches(#"\bnext year\b"#) {
            let year = calendar.component(.year, from: today) + 1
            return calendar.date(from: DateComponents(year: year, month: 1, day: 1))
        }
        if let m = text.memoryGroups(#"\bin (a|an|one|two|three|four|five|six|\d{1,2}) (day|week|month|year)s?\b"#) {
            let n = numbers[m[1]] ?? Int(m[1]) ?? 1
            let unit: Calendar.Component = ["day": .day, "week": .weekOfYear, "month": .month][m[2]] ?? .year
            return calendar.date(byAdding: unit, value: n, to: today)
        }
        if let m = text.memoryGroups(#"\b(in|from|starting|starting in|this|by|until|after)\s+(\#(months.joined(separator: "|")))\b"#),
           let index = months.firstIndex(of: m[2]) {
            let year = calendar.component(.year, from: today)
            var first = calendar.date(from: DateComponents(year: year, month: index + 1, day: 1))!
            if first <= today { first = calendar.date(byAdding: .year, value: 1, to: first)! }
            return first
        }
        if let m = text.memoryGroups(#"\b(on|this|next|starting)\s+(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b"#),
           let index = weekdays.firstIndex(of: m[2]) {
            return next(weekday: index + 1, after: today, calendar: calendar)
        }
        return nil
    }

    private static func fromModel(_ text: String, calendar: Calendar) -> Date? {
        if let m = text.memoryGroups(#"^(\d{4})-(\d{2})-(\d{2})"#),
           let y = Int(m[1]), let mo = Int(m[2]), let d = Int(m[3]), (1...12).contains(mo), (1...31).contains(d) {
            return calendar.date(from: DateComponents(year: y, month: mo, day: d))
        }
        if let m = text.memoryGroups(#"^(\d{4})-(\d{2})$"#), let y = Int(m[1]), let mo = Int(m[2]), (1...12).contains(mo) {
            return calendar.date(from: DateComponents(year: y, month: mo, day: 1))
        }
        return nil
    }

    private static func next(weekday: Int, after day: Date, calendar: Calendar) -> Date? {
        calendar.nextDate(after: day, matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime)
    }

    private static let numbers = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6]
    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// Words that put a fact in the future. Not a bare "I'll": "I'll always be vegetarian" is true now.
    private static let future = #"\b(i'm moving|im moving|i am moving|we're moving|moving to|will be moving|will move|will start|will join|going to move|going to start|about to|plan to move|planning to move|starting at|start at|start my new|i'm starting|i am starting|i'm joining|i am joining)\b"#
    /// Words for a change that starts on a day: a move, a new job, a switch.
    private static let change = #"\b(mov(e|es|ing)|start(s|ing)?|join(s|ing)?|begin(s|ning)?|switch(es|ing)?|transferr?(ing)?|relocat(e|es|ing)|will be|from (next|this|the) )"#
    /// Words that say it already happened.
    private static let past = #"\b(last (week|month|year)|ago|yesterday|moved|joined|started|since)\b"#
}

// MARK: - Extraction (P6, ADR-123)

/// One fact as the extraction model writes it.
struct ExtractedFact: Equatable, Sendable {
    var subject: String
    var predicate: String
    var value: String
    var section: FactSection
    var quote: String
    var sensitive: Bool = false
    var single: Bool = false
    var starts: String?
}

/// Marks a backend that runs on this device. Memory is extracted only by one
/// of these, never in the cloud (the system decides, not the model).
protocol OnDeviceLanguageModel: LocalLanguageModel {
    /// False for an instance that answers off the phone (Apple's Private Cloud
    /// Compute model shares the on-device model's type). Memory never uses it.
    var runsOnDevice: Bool { get }
}

extension OnDeviceLanguageModel {
    var runsOnDevice: Bool { true }
}

/// A model that can fill in the extraction format itself (Apple's guided
/// generation), so its answer can't fail to parse and needs no repair turn.
protocol GuidedFactExtracting: Sendable {
    /// The facts in `message`; throws when the model couldn't answer.
    func extractFacts(from message: String, instructions: String) async throws -> [ExtractedFact]
}

#if canImport(LiteRTLM)
extension LiteRTLMModel: OnDeviceLanguageModel {}
#endif
#if DEBUG
extension ScriptedModel: OnDeviceLanguageModel {}
#endif

/// Step 2 (§8.2): finds lasting facts in one message the user wrote.
/// - Runs only on an on-device model, with no tools.
/// - The first answer is free; it is parsed strictly. One that doesn't parse
///   gets exactly one repair, shown the expected shape; otherwise the event is
///   retried in a later run and dropped after a few attempts (P6).
/// - A fact is kept only if its quote (or value) is really in the message and
///   it carries no secret (I1).
struct FactExtractor: Sendable {
    enum Result: Equatable {
        case facts([ExtractedFact])
        /// The answer didn't parse twice.
        case failed(String)
        /// The model couldn't run (not loaded, GPU unavailable in the background…).
        /// Not the message's fault, so it doesn't count as an attempt.
        case unavailable(String)
    }

    let model: any OnDeviceLanguageModel
    var today: Date = Date()
    var calendar: Calendar = .current

    /// Sentinel the scripted test model recognises.
    static let sentinel = "[[MEMORY_EXTRACT]]"
    static let messageHeader = "The user's message:\n"

    func extract(_ message: String) async -> Result {
        if let guided = model as? any GuidedFactExtracting {
            do {
                let facts = try await guided.extractFacts(from: message, instructions: guidedInstructions)
                return .facts(facts.compactMap { Self.accept($0, message: message) })
            } catch is CancellationError {
                return .unavailable("Stopped.")
            } catch {
                // Counts as an attempt: a refusal would repeat on every run.
                return .failed("The model couldn't read the message: \(error.localizedDescription)")
            }
        }
        let first: [AgentMessage] = [.user(Self.messageHeader + message)]
        guard let raw = await ask(first) else { return .unavailable("The on-device model couldn't run.") }
        var parsed = Self.parse(raw)
        if parsed == nil {
            guard !Task.isCancelled else { return .unavailable("Stopped.") }
            let repair = first + [.assistant(raw), .user(Self.repair)]
            guard let again = await ask(repair) else { return .unavailable("The on-device model couldn't run.") }
            parsed = Self.parse(again)
        }
        guard let parsed else { return .failed("The model's answer didn't match the format twice.") }
        return .facts(parsed.compactMap { Self.accept($0, message: message) })
    }

    private func ask(_ transcript: [AgentMessage]) async -> String? {
        let prompt = GemmaChatTemplate.format(messages: transcript, tools: [], systemPromptOverride: system)
        var config = GenerationConfig.deterministic
        config.maxNewTokens = 512
        do {
            var text = ""
            for await chunk in try await model.generateApart(prompt: prompt, config: config) {
                text += chunk
            }
            if Task.isCancelled || text.contains("[Generation error:") { return nil }
            return text
        } catch {
            return nil
        }
    }

    var system: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        return """
        \(Self.sentinel)
        You keep the user's private memory on their phone. Read the user's message and list the lasting facts it states about the user, or about the people, places and things in their life.
        Include identity, work, relationships, places, routines, preferences, goals and commitments that will still be true next week.
        Skip requests to the assistant, questions, plans for today only, and anything the message doesn't say.
        Never include passwords, codes, or card or account numbers.
        Use "user" as the subject for the user. Copy the words that state each fact into quote.
        A fact that starts later, such as a move next month or a new job in March, gets starts: the day it begins, as YYYY-MM-DD.
        Example message: "My manager Maya wants the report by Friday. I'm vegetarian, so pick somewhere veggie."
        Example answer: {"facts":[{"subject":"user","predicate":"manager","value":"Maya","section":"people","quote":"My manager Maya","single":true},{"subject":"user","predicate":"diet","value":"vegetarian","section":"preferences","quote":"I'm vegetarian","single":true}]}
        If nothing qualifies, answer {"facts":[]}.
        Today is \(formatter.string(from: today)).
        """
    }

    /// The same instructions for a model that fills in the format itself:
    /// no test sentinel, and no JSON to copy.
    var guidedInstructions: String {
        system.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix(Self.sentinel) && !$0.hasPrefix("Example answer:") && !$0.hasPrefix("If nothing qualifies") }
            .joined(separator: "\n")
            + "\nIf nothing qualifies, return no facts."
    }

    static let repair = """
    That wasn't valid JSON for the format. Answer with only one JSON object, no other text, shaped like:
    {"facts":[{"subject":"user","predicate":"snake_case_relation","value":"a few words","section":"identity|people|work|routines|preferences|goals|places","quote":"exact words from the message","sensitive":false,"single":false,"starts":null}]}
    """

    /// Reads the model's answer strictly: the whole answer (fences allowed)
    /// must be one JSON object with a `facts` array whose items carry string
    /// `subject`, `predicate`, `value` and `quote`. A made-up section is filed
    /// in identity for the user, else in people (ADR-123). Returns nil when it
    /// doesn't parse.
    static func parse(_ raw: String) -> [ExtractedFact]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["```json", "```"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count); break }
        if text.hasSuffix("```") { text.removeLast(3) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["facts"] as? [Any] else { return nil }
        var facts: [ExtractedFact] = []
        for item in items {
            guard let fact = item as? [String: Any],
                  let subject = fact["subject"] as? String,
                  let predicate = fact["predicate"] as? String,
                  let value = fact["value"] as? String,
                  let quote = fact["quote"] as? String else { return nil }
            if let s = fact["sensitive"], !(s is NSNull), (s as? Bool) == nil { return nil }
            if let s = fact["single"], !(s is NSNull), (s as? Bool) == nil { return nil }
            let section = (fact["section"] as? String).flatMap(FactSection.init(rawValue:)).flatMap { $0 == .notes ? nil : $0 }
                ?? (MemoryNormalize.subject(subject) == MemoryFact.user ? .identity : .people)
            facts.append(ExtractedFact(
                subject: subject, predicate: predicate, value: value, section: section, quote: quote,
                sensitive: fact["sensitive"] as? Bool ?? false,
                single: fact["single"] as? Bool ?? false,
                starts: fact["starts"] as? String))
        }
        return facts
    }

    private static let changeDay = #"^(move|moving|relocation|start|starting|join|joining|new_job)_(date|day|on|time|when)$"#
    private static let vague: Set<String> = ["new job", "a new job", "job", "new", "work", "unknown", "n a", "none", "soon", "next month", "next week"]

    /// Keeps a fact only if the message really says it and it is safe to keep.
    static func accept(_ fact: ExtractedFact, message: String) -> ExtractedFact? {
        let subject = MemoryNormalize.subject(fact.subject)
        let predicate = MemoryNormalize.predicate(fact.predicate)
        let value = fact.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty, !predicate.isEmpty, !value.isEmpty,
              subject.count <= 60, predicate.count <= 40, value.count <= 120 else { return nil }
        guard MemoryFilters.safeToKeep("\(predicate) \(value)") else { return nil }
        if predicate.memoryMatches(changeDay) || vague.contains(MemoryNormalize.value(value)) { return nil }
        let said = Set(MemoryNormalize.words(message))
        let quoteWords = MemoryNormalize.words(fact.quote)
        let quoted = !quoteWords.isEmpty && quoteWords.allSatisfy(said.contains)
        let valueSaid = MemoryNormalize.words(value).allSatisfy(said.contains)
        guard quoted || valueSaid else { return nil }
        var kept = fact
        kept.subject = subject
        kept.predicate = predicate
        kept.value = value
        kept.quote = fact.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        return kept
    }
}

// MARK: - Regex helpers

extension String {
    func memoryMatches(_ pattern: String, caseInsensitive: Bool = true) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return false }
        return regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)) != nil
    }

    func memoryReplacing(_ pattern: String, with template: String, caseInsensitive: Bool = true) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return self }
        return regex.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: template)
    }

    /// The first match's groups (index 0 is the whole match); "" for a group that didn't take part.
    func memoryGroups(_ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: self).map { String(self[$0]).lowercased() } ?? ""
        }
    }
}
