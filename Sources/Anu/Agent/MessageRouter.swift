import Foundation

/// Which conversation mode a user message should run in.
enum ChatMode: Equatable {
    /// Casual conversation — short friendly persona prompt, no tool protocol,
    /// warmer sampling. Faster (small prefill) and more natural.
    case chat
    /// Task execution — full agent prompt with tool schemas and the ReAct
    /// loop, cool sampling for JSON discipline.
    case agent
}

/// Heuristic v1 router between chat and agent mode.
///
/// Philosophy: only escalate to the heavyweight agent prompt when the message
/// clearly smells like a task; default to chat. Misrouting a task to chat
/// degrades gracefully (the model still answers, just without tools).
enum MessageRouter {

    private static let agentKeywords: [String] = [
        // computation
        "calculate", "compute", "convert", "how many", "how much",
        "sum of", "average", "percent",
        // information retrieval
        "search", "look up", "latest", "news", "current", "today's",
        "weather", "price", "stock",
        // generation / coding tasks
        "write a", "write me", "write an", "draft", "essay", "summarize",
        "translate", "code", "script", "function", "debug", "regex",
        // explicit agentic asks
        "step by step", "plan", "research",
    ]

    /// Matches arithmetic-looking content: a digit joined to another digit by
    /// an operator ("12*8", "3 + 4", "2^10"), or a trailing percent ("15%").
    private static let mathPattern = try! NSRegularExpression(
        pattern: #"\d\s*[\+\-\*\/\^×÷]\s*\d|\d\s*%"#
    )

    static func route(_ message: String) -> ChatMode {
        let lower = message.lowercased()

        if agentKeywords.contains(where: { lower.contains($0) }) {
            return .agent
        }

        let range = NSRange(lower.startIndex..., in: lower)
        if mathPattern.firstMatch(in: lower, range: range) != nil {
            return .agent
        }

        // Long, structured messages are usually tasks
        if message.count > 280 {
            return .agent
        }

        return .chat
    }
}
