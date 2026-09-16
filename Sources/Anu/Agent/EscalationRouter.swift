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

        Choose ESCALATE when the request is demanding OR likely beyond your \
        knowledge:
        - long-form writing, non-trivial code, or multi-step reasoning
        - specialized or expert-level topics
        - specific facts about particular people, places, products, events, or \
        head-to-head comparisons that you are not confident you know accurately
        If answering would mean guessing at facts, choose ESCALATE.

        Choose LOCAL for casual chat, greetings, opinions, and simple questions \
        you can answer accurately and concisely yourself.

        Reply with EXACTLY one word and nothing else: LOCAL or ESCALATE.
        """
    }

    /// Interprets the model's answer. `true` = escalate to the larger model.
    /// Pure and `nonisolated` so it's directly unit-testable. Fail-safe to
    /// LOCAL on empty / ambiguous / negated output — the router can never force
    /// an escalation it isn't clearly asked for.
    nonisolated static func shouldEscalate(from output: String) -> Bool {
        let lower = output.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return false }
        // No "escalate" anywhere → stay local (covers "LOCAL", "local, simple", …).
        guard let esc = lower.range(of: "escalate") else { return false }
        // If "local" is stated before the first "escalate", LOCAL wins even when
        // the model echoes both words ("LOCAL — no need to escalate").
        if let loc = lower.range(of: "local"), loc.lowerBound < esc.lowerBound { return false }
        // A negation in the few words right before "escalate" means stay LOCAL —
        // small models don't always obey "one word" and emit "do not escalate",
        // "no need to escalate", "I don't think we should escalate", etc. Reading
        // those as ESCALATE would trigger a spurious cloud call.
        let before = String(lower[..<esc.lowerBound])
        let recentWords = before.split { !$0.isLetter && $0 != "'" }.suffix(4).map(String.init)
        let negations: Set<String> = [
            "not", "n't", "never", "no", "without", "avoid",
            "don't", "doesn't", "cannot", "can't", "shouldn't", "wouldn't",
        ]
        if recentWords.contains(where: { negations.contains($0) }) { return false }
        return true
    }
}
