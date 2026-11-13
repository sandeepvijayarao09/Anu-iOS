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
            "\\b(added|put)\\s+(it|this|that)\\s+(to|on|in)\\s+your\\s+(calendar|reminders)\\b",
        ]
        // The patterns are constants; a failure here is a programming error.
        return try! NSRegularExpression(pattern: patterns.joined(separator: "|"), options: [.caseInsensitive])
    }()

    /// Model control markup that leaked into text. It means a call wasn't
    /// parsed, and it must never be shown as an answer.
    private static let markup: NSRegularExpression = {
        let pattern = #"<\|tool_call>|<tool_call\|>|<\|"\|>|<\|tool_response>|<start_of_turn>|<end_of_turn>|"tool_call"\s*:"#
        return try! NSRegularExpression(pattern: pattern)
    }()

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
