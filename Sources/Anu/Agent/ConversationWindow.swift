import Foundation

/// Trims conversation history to a budget before prompt building.
///
/// Strategy: always keep the latest messages; drop the oldest ones first.
/// Trimming starts at user-message boundaries so the window opens with a
/// user turn — the chat template folds the system prompt into the first
/// user turn it sees, so a freshly trimmed window keeps its instructions.
///
/// The default window is budgeted in tokens with the calibrated rates
/// (ADR-041): prose and tool JSON are estimated at their own rates, then
/// scaled by what the on-device runtime's counts taught `TokenCalibration`.
enum ConversationWindow {

    /// Character budget for `windowed(_:budget:)` (≈700 tokens at 4 chars a
    /// token). Kept lean so prefill stays fast on every turn — the biggest
    /// per-turn latency lever for a 4B on-device model.
    static let defaultBudget = 2800

    /// The default window in tokens: the same 2,800 characters of prose at the
    /// raw 3.5 characters a token, so an uncalibrated window is unchanged.
    static let defaultTokenBudget = 800

    /// The default window: a token budget with the shared calibration.
    static func windowed(_ messages: [AgentMessage]) -> [AgentMessage] {
        windowed(messages, tokenBudget: defaultTokenBudget, calibration: .shared)
    }

    /// Budgeted in calibrated tokens, prose and JSON at their own rates.
    static func windowed(_ messages: [AgentMessage], tokenBudget: Int, calibration: TokenCalibration) -> [AgentMessage] {
        trim(messages, budget: tokenBudget) {
            calibration.estimate($0.content, kind: TokenCalibration.kind(of: $0))
        }
    }

    /// Budgeted in characters.
    static func windowed(_ messages: [AgentMessage], budget: Int) -> [AgentMessage] {
        trim(messages, budget: budget) { $0.content.count }
    }

    private static func trim(_ messages: [AgentMessage], budget: Int, cost: (AgentMessage) -> Int) -> [AgentMessage] {
        var costs = messages.map(cost)
        var total = costs.reduce(0, +)
        guard total > budget else { return messages }

        var result = messages
        // Drop the oldest turns until within budget AND the window opens on a
        // user turn. Both conditions matter: the chat template folds the system
        // prompt into the FIRST user turn it sees, so a window starting on an
        // assistant turn (reachable e.g. after two consecutive assistant turns
        // at the head, like a normal reply followed by an error message) would
        // silently drop the persona, tool protocol, and memory block.
        while result.count > 1, total > budget || result.first?.role != .user {
            result.removeFirst()
            total -= costs.removeFirst()
        }
        return result
    }
}
