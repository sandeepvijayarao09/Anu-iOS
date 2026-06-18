import Foundation

/// Trims conversation history to a character budget before prompt building.
///
/// Strategy: always keep the latest messages; drop the oldest ones first.
/// Trimming starts at user-message boundaries so the window opens with a
/// user turn — the chat template folds the system prompt into the first
/// user turn it sees, so a freshly trimmed window keeps its instructions.
enum ConversationWindow {

    /// ~4 chars/token heuristic. The Core ML model sees 512 tokens and the
    /// LiteRT engine 2048 total (prompt + response); budget the prompt to
    /// leave generation room. Kept lean (≈700 tokens) so prefill stays fast on
    /// every turn — the biggest per-turn latency lever for a 4B on-device model.
    static let defaultBudget = 2800

    static func windowed(_ messages: [AgentMessage], budget: Int = defaultBudget) -> [AgentMessage] {
        var total = messages.reduce(0) { $0 + $1.content.count }
        guard total > budget else { return messages }

        var result = messages
        while total > budget, result.count > 1 {
            let dropped = result.removeFirst()
            total -= dropped.content.count
            // Keep dropping until the window starts at a user turn so the
            // template has somewhere to fold the system prompt.
            while let first = result.first, first.role != .user, result.count > 1 {
                total -= first.content.count
                result.removeFirst()
            }
        }
        return result
    }
}
