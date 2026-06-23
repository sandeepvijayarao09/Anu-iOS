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
        // Drop the oldest turns until within budget AND the window opens on a
        // user turn. Both conditions matter: the chat template folds the system
        // prompt into the FIRST user turn it sees, so a window starting on an
        // assistant turn (reachable e.g. after two consecutive assistant turns
        // at the head, like a normal reply followed by an error message) would
        // silently drop the persona, tool protocol, and memory block.
        while result.count > 1, total > budget || result.first?.role != .user {
            total -= result.removeFirst().content.count
        }
        return result
    }
}
