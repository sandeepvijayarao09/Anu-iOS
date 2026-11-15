import Foundation

// MARK: - Action claims

/// Spots answers that claim an action was done (ported from Anu Android,
/// ADR-027). Deliberately narrow: completed actions in the first person ("I've
/// scheduled", "I sent") and finished states ("the invite has been sent",
/// "it's now on your calendar"). Proposals ("I can schedule…") and finds ("I've
/// found a slot") are not claims.
///
/// On Android, E4B claimed an invite it never requested. Nothing had happened,
/// but the chat showed a false claim; this check is what catches it.
enum ActionClaims {
    private static let acts = "scheduled|booked|created|added|sent|invited|emailed|set up|put|moved|rescheduled|"
        + "cancell?ed|deleted|removed|replied|forwarded|messaged|texted|called|opened|saved|set"

    private static let claim: NSRegularExpression = {
        let patterns = [
            "\\b(i'?ve|i have|i|we'?ve|we have)\\s+(just\\s+|now\\s+|also\\s+|already\\s+|successfully\\s+)?(\(acts))\\b",
            "\\b(invitation|invite|email|message|text|event|meeting|reminder|timer|alarm)s?\\s+(has|have)\\s+(just\\s+|now\\s+)?been\\s+(\(acts))\\b",
            "\\b(is|are|it'?s)\\s+now\\s+(on|in)\\s+your\\s+(calendar|reminders)\\b",
            // "8 am tomorrow's alarm's set" (Apple's on-device model, on device)
            "\\b(invitation|invite|email|message|text|event|meeting|reminder|timer|alarm)s?('s|\\s+is|\\s+are)\\s+(now\\s+|all\\s+)?(set|scheduled|booked|created|added|sent)\\b",
            "\\b(you'?re|you are)\\s+all\\s+set\\b",
            "\\b(added|put)\\s+(it|this|that)\\s+(to|on|in)\\s+your\\s+(calendar|reminders)\\b",
        ]
        // The patterns are constants; a failure here is a programming error.
        return try! NSRegularExpression(pattern: patterns.joined(separator: "|"), options: [.caseInsensitive]) // swiftlint:disable:this force_try
    }()

    /// Model control markup that leaked into text. It means a call wasn't
    /// parsed, and it must never be shown as an answer.
    private static let markup: NSRegularExpression = {
        let pattern = #"<\|tool_call>|<tool_call\|>|<\|"\|>|<\|tool_response>|<start_of_turn>|<end_of_turn>|"tool_call"\s*:"#
        return try! NSRegularExpression(pattern: pattern) // swiftlint:disable:this force_try
    }()

    // MARK: Memory claims (Android ADR-089)

    /// Up to eight words inside one sentence, as in "keep Alex's usual 6 PM
    /// finish time in mind", which E4B wrote on Android's emulator.
    private static let gap = "([^\\s.!?]+\\s+){0,8}?"

    /// Words that acknowledge before a bare "Noted", as in "Got it, noted."
    private static let ack = "got it|got that|ok|okay|sure|sure thing|alright|all right|thanks|thank you|great|perfect|"
        + "understood|of course|absolutely|yes|lovely|wonderful|excellent"

    /// "I've noted…", "I'll remember…", "I'll keep that in mind", "Noted!".
    /// Not proposals ("Shall I remember that?"), recall ("I remember you're
    /// vegetarian") or other people's words ("as you noted"). Ported from
    /// Android's `ActionClaims.MEMORY_CLAIM`.
    private static let memoryClaim: NSRegularExpression = {
        let patterns = [
            "(?<!\\b(?:as|like)\\s)\\b(i'?ve|i have|we'?ve|we have)\\s+(just\\s+|now\\s+|also\\s+|already\\s+)?"
                + "(noted|remembered|memori[sz]ed|made\\s+(a\\s+)?notes?|taken\\s+(a\\s+)?note|jotted|written\\s+(that|this|it)\\s+down|"
                + "(kept|borne)\\s+\(gap)in\\s+mind|got\\s+(that|this|it)\\s+(noted|down))\\b",
            "\\bi\\s+(just\\s+|also\\s+)?(made\\s+(a\\s+)?note|took\\s+(a\\s+)?note|jotted|(wrote|noted)\\s+(that|this|it)\\s+down)\\b",
            "\\b(i'?ve|i have|i|we'?ve|we have)\\s+(just\\s+|now\\s+|also\\s+|already\\s+)?(saved|stored|added|put|kept|recorded)\\s+"
                + "\(gap)(to|in|into)\\s+(your\\s+|my\\s+|the\\s+)?memory\\b",
            "\\b(i'?ve|i have)\\s+(just\\s+|now\\s+|also\\s+)?updated\\s+(your|my)\\s+(memory|profile)\\b",
            "(?<!\\b(?:as|like)\\s)\\b(i'?ve|i have|we'?ve|we have)\\s+[^.!?\\n]{1,80}?\\band\\s+(also\\s+)?"
                + "(noted\\s+that|made\\s+(a\\s+)?note|(saved|stored|added|kept)\\s+\(gap)(to|in|into)\\s+(your\\s+|my\\s+|the\\s+)?memory)\\b",
            "\\b(i'?ll|i will|i'?m going to)\\s+(always\\s+|definitely\\s+|be sure to\\s+|make sure to\\s+)?"
                + "(remember|memori[sz]e|(keep|bear)\\s+\(gap)in\\s+mind|make\\s+(a\\s+)?note|note\\s+(that|this|it|down)|"
                + "take\\s+(a\\s+)?note|jot\\s+(that|this|it)\\s+down|(save|store|add|keep)\\s+\(gap)(to|in|into)\\s+(your\\s+|my\\s+)?memory)\\b",
            "\\b(i'?ll|i will)\\s+[^.!?\\n]{1,80}?\\band\\s+(also\\s+)?(remember|(keep|bear)\\s+\(gap)in\\s+mind|make\\s+(a\\s+)?note)\\b",
            "(^|[.!?]\\s+|\\n\\s*)[*_]{0,2}((\(ack))\\s*[,.!—–-]?\\s+)?(duly\\s+)?noted[*_]{0,2}"
                + "(\\s*[!.,:;—–-]|\\s*(\\n|$)|\\s+(that|it|down)\\b)",
            "\\b(that|this|it)('s|\\s+is|\\s+has)\\s+(now\\s+|been\\s+|already\\s+){0,2}"
                + "(noted|remembered|(saved|stored|kept|added)\\s+(to|in)\\s+(your\\s+|my\\s+)?memory)\\b",
            "\\byour\\s+\\w+(\\s+\\w+)?\\s+(has|have)\\s+been\\s+(noted|remembered)\\b",
        ]
        return try! NSRegularExpression( // swiftlint:disable:this force_try
            pattern: patterns.joined(separator: "|"), options: [.caseInsensitive, .anchorsMatchLines])
    }()

    /// The only tool whose write backs a memory claim.
    static let rememberTool = "memory_remember"

    static func claimsMemory(_ answer: String) -> Bool {
        matches(memoryClaim, answer.replacingOccurrences(of: "’", with: "'"))
    }

    /// Sent with the one repair attempt after a memory claim. It allows what a
    /// tool result confirms, and gives no example answer (E4B copied one word
    /// for word on Android).
    static let nothingRememberedNote = """
    Note from Anu: nothing from the user's newest message has been saved to memory yet. \
    Don't say "noted", "I'll remember" or "I'll keep that in mind" unless a tool result confirms a save. \
    Answer without saying it's saved. If the user declined, say it won't be remembered.
    """

    /// Added after `nothingRememberedNote` only when the turn offers the
    /// remember tool; a turn without it has nothing to call.
    static let rememberHint = "If the user asked you to remember it and didn't decline, call memory_remember now."

    /// Appended to an answer that still claims a save after the repair.
    static let notRememberedWarning = "Note from Anu: nothing was saved to memory."

    /// Appended when an answer still claims both an action and a save.
    static let notDoneOrRememberedWarning = "Note from Anu: nothing was actually created or sent, and nothing was saved to memory."

    static func claimsAction(_ answer: String) -> Bool {
        matches(claim, answer.replacingOccurrences(of: "’", with: "'"))
    }

    static func hasControlMarkup(_ answer: String) -> Bool {
        matches(markup, answer)
    }

    /// The answer with control markup cut out, for when the repair also leaked it.
    static func strippingMarkup(_ answer: String) -> String {
        let range = NSRange(answer.startIndex..., in: answer)
        return markup.stringByReplacingMatches(in: answer, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sent with the one repair attempt when an answer claimed an action.
    static let nothingDoneNote = """
    Note from Anu: in this conversation you have not created, sent or changed anything yet. Never say you have. \
    If the user wants it done, call the tool now; the user will be asked to approve it. \
    Otherwise, say what you propose and ask.
    """

    /// Sent with the one repair attempt when an answer leaked tool-call markup.
    static let markupNote = """
    Note from Anu: your last reply contained raw tool-call markup. Either call the tool using the JSON format, \
    or answer in plain words.
    """

    /// Appended to an answer that still claims an action after the repair.
    static let notDoneWarning = "Note from Anu: nothing was actually created or sent."

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
