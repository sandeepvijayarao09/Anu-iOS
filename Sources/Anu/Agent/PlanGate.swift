import Foundation

/// Decides whether a request is multi-step enough to deserve the full
/// Planner→Executor→Critic pipeline, versus the cheaper single-shot ReAct loop.
///
/// Philosophy (mirrors `MessageRouter`): be CONSERVATIVE. Only clearly
/// multi-step requests engage the pipeline; everything else stays on the fast
/// path. A false negative just runs the existing loop (fine); a false positive
/// pays ~13 model calls for nothing, so the bar is deliberately high.
///
/// Only consulted once the message has already been routed to `.onDeviceAgent`,
/// so casual chat and cloud requests never reach here.
enum PlanGate {

    /// Explicit sequencing language — the strongest multi-step signal.
    private static let sequencingMarkers: [String] = [
        "and then", ", then ", "then ", "after that", "afterward", "afterwards",
        "followed by", "after you", "once you", "once done", "next,", "finally",
        "lastly", "step 1", "step 2",
    ]

    /// Distinct task domains. Two or more *different* domains in one message
    /// implies the request can't be done in a single specialist turn.
    private static let domainKeywords: [String: [String]] = [
        "web": ["search", "look up", "latest", "news", "current", "weather", "find out", "price"],
        "math": ["calculate", "compute", "convert", "how much", "how many", "percentage"],
        "write": ["write", "draft", "summarize", "summary", "email", "essay", "translate", "rewrite"],
        "code": ["code", "function", "script", "debug", "regex", "program"],
        "device": ["remind", "reminder", "calendar", "schedule", "event", "contact", "appointment"],
    ]

    static func shouldPlan(task: TaskClassification, message: String) -> Bool {
        let lower = message.lowercased()

        // Too short to be multi-step (greetings, single calcs, lookups).
        guard message.count >= 24 else { return false }

        // 1) Explicit sequencing language.
        if sequencingMarkers.contains(where: { lower.contains($0) }) {
            return true
        }

        // 2) A numbered or bulleted list with at least two items.
        if hasMultiItemList(lower) {
            return true
        }

        // 3) Two or more distinct task domains in one request.
        let domains = domainKeywords.filter { _, words in
            words.contains { lower.contains($0) }
        }
        if domains.count >= 2 {
            return true
        }

        return false
    }

    /// Detects "1. … 2. …", "1) … 2) …", or two or more "- "/"* " bullet lines.
    private static func hasMultiItemList(_ text: String) -> Bool {
        let numbered = matchCount(#"(?m)^\s*\d+[\.\)]\s+\S"#, in: text)
        if numbered >= 2 { return true }
        let bullets = matchCount(#"(?m)^\s*[-*]\s+\S"#, in: text)
        return bullets >= 2
    }

    private static func matchCount(_ pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let range = NSRange(text.startIndex..., in: text)
        return regex.numberOfMatches(in: text, range: range)
    }
}
