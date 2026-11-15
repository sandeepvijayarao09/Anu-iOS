import Foundation

// AI Email and AI Scheduling (Android parity #11): which skill a chat message
// belongs to, and so which tools the model is offered for it. Ported from Anu
// Android's `core:router` SkillDetector — transparent keyword rules, replayed
// over the user's turns so a short follow-up ("yes, send it", "how about
// Friday?") keeps its skill. Small models do better with fewer tools (§7.3).

enum AssistantSkill: String, Sendable, Equatable {
    /// Nothing specific: the default tool set.
    case chat
    /// AI Email: Gmail tools plus contacts and calendar lookups.
    case email
    /// AI Scheduling: calendar plus contacts.
    case scheduling
    /// Texts and chat apps. Anu for iOS can't read them, so it keeps the
    /// default tools; it's here so "reply" after a text isn't taken for email.
    case messages
    /// Another area Android routes elsewhere (memory, notes, an app): the
    /// default tools, but it ends an email or scheduling follow-up.
    case other
}

enum SkillDetector {
    // MARK: Rules (Android SkillDetector.kt, adapted)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) // swiftlint:disable:this force_try
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// "Remember Maya's email is…" is about memory, not email.
    private static let memory = regex(
        #"^\W*(please\s+)?(remember|don'?t forget|note that|keep in mind|forget (that|about|what|my|i)\b)|\b(what do you (know|remember) about|what have you learned|do you remember)\b"#)

    /// "In the Gmail app, archive…" means tapping in that app.
    private static let inAnApp = regex(
        #"\b(in|on|using|with|open|launch|go to) (the |my )?(?!(a|an|the|my|this|that|your|our|their|his|her|new|one|an?other) app\b)[\p{L}\p{N}][\p{L}\p{N}&.'’ +-]{0,30}? app\b"#)

    /// Words that only mean email.
    private static let email = regex(
        #"\b(e-?mails?|e-?mailed|gmail|inbox|mail from|newsletter|subject line|cc)\b"#)

    /// Words that only mean texts and chat apps.
    private static let messages = regex(
        #"\b(texts|texted|texting|text (me|him|her|them|back|from)|(a|her|his|their|last|latest|new|unread) texts?|['’]s texts?|sms|whatsapp|telegram|messenger|signal app|on signal|slack|discord|group ?chats?|chats|dms?|messages?|messaged|imessages?)\b"#)

    private static let textCommand = regex(#"^\W*(please\s+)?(text|txt|message|msg|dm|whatsapp|imessage)\b(?!\s+of\b)"#)
    private static let textDraft = regex(#"\b(draft|write|compose|prepare|type up)\b(\s+\S+){0,3}?\s+(text|message|sms)\b"#)

    /// Words for either; they mean email unless the chat was about texts.
    private static let correspondence = regex(
        #"\b(repl(y|ies|ied)|draft|forward (it|this|that|them)|unread|sent me|wrote (to )?me|get back to)\b"#)

    private static let scheduling = regex(
        #"\b(calendar|schedul\w*|meeting|meetings|appointment|agenda|free (time|slot)|busy|availab\w*|invite|reschedul\w*|book (a|an|me)|what'?s on my|my (day|week|morning|afternoon))\b"#)

    private static let noteWords = regex(#"\b(notes?|notepad|(grocery|groceries|shopping) lists?)\b"#)
    private static let calendarWords = regex(#"\b(calendar|meetings?|appointments?|invite|schedul\w*|reschedul\w*)\b"#)

    private static let phone = regex(#"\+?\d[\d ().-]{5,}\d"#)
    private static let isoDate = regex(#"\d{4}-\d{2}-\d{2}"#)

    private static func hasPhoneNumber(_ text: String) -> Bool {
        let ns = text as NSString
        return phone.matches(in: text, range: NSRange(location: 0, length: ns.length)).contains { match in
            let value = ns.substring(with: match.range)
            return (7...15).contains(value.filter(\.isNumber).count) && !matches(isoDate, value)
        }
    }

    /// The skill `text`'s own words name, or nil.
    static func keywords(_ text: String, previous: AssistantSkill? = nil) -> AssistantSkill? {
        if matches(memory, text) || matches(inAnApp, text) { return .other }
        if matches(email, text) { return .email }
        if matches(messages, text) || matches(textCommand, text) || matches(textDraft, text) { return .messages }
        // Before scheduling: a reply that proposes a time needs the reply tools,
        // which include the calendar lookups.
        if matches(correspondence, text) {
            return previous == .messages || hasPhoneNumber(text) ? .messages : .email
        }
        // "What's on my groceries note?" is a note unless the calendar is named.
        if matches(noteWords, text), !matches(calendarWords, text) { return .other }
        if matches(scheduling, text) { return .scheduling }
        return nil
    }

    // MARK: Follow-ups

    static let followUpCharacters = 80
    static let maxFollowUps = 3
    static let replayTurns = 20

    private static let questionOpeners: Set<String> = [
        "who", "what", "what's", "when", "where", "which", "why", "how", "how's", "whose", "whom",
    ]
    /// Words that refer to something said before.
    private static let pointsBack: Set<String> = [
        "it", "it's", "its", "that", "this", "these", "those", "them", "they", "their", "he", "she", "him", "her", "his",
        "one", "ones", "there", "then", "about", "instead", "too", "also", "else", "again", "more", "another", "same",
        "else's", "yours", "mine",
    ]

    /// A short message that leans on the one before. A new question that
    /// stands on its own is not one, however short.
    static func isFollowUp(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= followUpCharacters else { return false }
        let words = trimmed.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        let standsAlone = words.count >= 3 && questionOpeners.contains(words[0]) && !words.contains { pointsBack.contains($0) }
        return !standsAlone
    }

    /// The skill for one message, given the skill of the turn before.
    static func detect(_ text: String, previous: AssistantSkill? = nil) -> AssistantSkill {
        if let found = keywords(text, previous: previous) { return found }
        if let previous, previous != .chat, previous != .other, isFollowUp(text) { return previous }
        return .chat
    }

    /// The skill for the last of `turns` (the user's messages, oldest first).
    /// A skill carries over at most `maxFollowUps` short follow-ups in a row.
    static func detect(turns: [String]) -> AssistantSkill {
        var skill = AssistantSkill.chat
        var followUps = 0
        for text in turns.suffix(replayTurns) {
            if let found = keywords(text, previous: skill) {
                skill = found
                followUps = 0
            } else if skill != .chat, skill != .other, isFollowUp(text), followUps < maxFollowUps {
                followUps += 1
            } else {
                skill = .chat
                followUps = 0
            }
        }
        return skill
    }

    // MARK: Tool bundles

    /// Tools only an email turn is offered.
    static let emailOnlyTools: Set<String> = Set(GmailTools.names)

    /// The tool names a skill offers, in order, or nil for the default set.
    static func bundle(for skill: AssistantSkill) -> [String]? {
        switch skill {
        case .email: return GmailTools.names + ["contacts", "calendar", "datetime"]
        case .scheduling: return ["calendar", "contacts", "datetime"]
        case .chat, .messages, .other: return nil
        }
    }

    /// The tools to offer the model for `skill`, from `all` registered ones.
    /// Default turns get everything except the email-only tools.
    static func tools(for skill: AssistantSkill, from all: [any Tool]) -> [any Tool] {
        guard let names = bundle(for: skill) else {
            return all.filter { !emailOnlyTools.contains($0.name) }
        }
        let byName = Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return names.compactMap { byName[$0] }
    }

    /// Whether the skill's tools need the agent path (not tool-less chat).
    static func needsTools(_ skill: AssistantSkill) -> Bool { bundle(for: skill) != nil }
}

extension AgentOrchestrator {
    /// The user's messages this conversation, ending with `latest`.
    func skillTurns(endingWith latest: String? = nil) -> [String] {
        var turns = conversationHistory.filter { $0.role == .user }.map(\.content)
        if let latest, turns.last != latest { turns.append(latest) }
        return turns
    }

    /// The skill of the current turn (AI Email / AI Scheduling).
    var currentSkill: AssistantSkill { SkillDetector.detect(turns: skillTurns()) }

    /// What the ReAct loop offers the model this turn: an AI Email or AI
    /// Scheduling bundle, or else the tools this turn's words point at,
    /// within the prompt's tool budget (`ToolSelector`).
    var toolsForCurrentTurn: [any Tool] {
        let skill = currentSkill
        let access = MemoryAccess(session: activeSession)
        let tools = SkillDetector.tools(for: skill, from: toolRegistry.allTools.filter { access.offers($0.name) })
        guard !SkillDetector.needsTools(skill) else { return tools }
        return ToolSelector.select(tools, turns: skillTurns(),
                                   escalation: CloudProvider.resolved()?.escalationToolName)
    }
}
