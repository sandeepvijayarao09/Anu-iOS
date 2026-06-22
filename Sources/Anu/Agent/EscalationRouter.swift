import Foundation

// MARK: - Escalation router (LLM-as-router)

/// Lets the small on-device model decide whether a task exceeds it and should
/// be handed up to the larger cloud model — a dual-LLM router on top of the
/// cheap heuristic `ModelClassifier`.
///
/// This type is pure (prompt + parser), mirroring `Planner`/`PlanParser`. The
/// orchestrator owns the actual model call (`judgeEscalation`); here we only
/// build the instruction and interpret the one-word answer. Any ambiguity
/// defaults to staying LOCAL — the router can never force an escalation it
/// isn't confident about.
enum EscalationRouter {

    /// The router answers with a single word, so a tiny budget is plenty and
    /// keeps the extra on-device step fast.
    static let maxTokens = 8

    /// Instruction folded into the prompt as a system override. Embeds the
    /// `[[ROUTER]]` sentinel so `ScriptedModel` can drive this path in tests
    /// (same mechanism `Planner` uses with `[[PLANNER]]`).
    static func systemPrompt() -> String {
        """
        You are a small on-device model acting as a router. [[ROUTER]]
        Decide whether YOU can answer the user's request well on your own, or \
        whether it needs a larger, more capable model.

        Escalate ONLY when the request is genuinely demanding: long-form \
        writing, non-trivial code, multi-step reasoning, or specialized \
        expertise beyond a small model. For chat, quick facts, simple \
        questions, or short tasks, stay local.

        Reply with EXACTLY one word and nothing else: LOCAL or ESCALATE.
        """
    }

    /// Interprets the model's answer. `true` = escalate to the larger model.
    /// Pure and `nonisolated` so it's directly unit-testable. Fail-safe to
    /// LOCAL on empty/ambiguous output.
    nonisolated static func shouldEscalate(from output: String) -> Bool {
        let lower = output.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return false }
        // A leading LOCAL wins even if the model echoes both words.
        if lower.hasPrefix("local") { return false }
        return lower.contains("escalate")
    }
}
