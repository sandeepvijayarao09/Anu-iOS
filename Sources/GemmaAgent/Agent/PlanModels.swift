import Foundation

// MARK: - Specialist sub-agents

/// A specialist sub-agent persona. Each one runs the same bounded ReAct loop
/// but with a focused system prompt and a *subset* of the registered tools, so
/// the planner can dispatch each step to the agent best suited to it.
///
/// The `[[SUBAGENT:<name>]]` marker in each prompt is innocuous instruction
/// text the real model ignores; `ScriptedModel` uses it in DEBUG to route test
/// responses.
enum Specialist: String, Codable, Sendable, CaseIterable {
    case researcher
    case coder
    case mathematician
    case writer
    case generalist

    /// Names of the registry tools this specialist is allowed to call.
    /// `.generalist` is treated as "all tools" by the executor regardless of
    /// this list, but the full set is listed here for determinism in tests.
    var allowedToolNames: Set<String> {
        switch self {
        case .researcher:
            return ["web_search", "datetime", "calendar", "reminders", "contacts"]
        case .coder:
            return ["calculator", "escalate_to_gemini"]
        case .mathematician:
            return ["calculator", "unit_converter"]
        case .writer:
            return ["escalate_to_gemini", "datetime"]
        case .generalist:
            return ["calculator", "web_search", "datetime", "unit_converter",
                    "escalate_to_gemini", "reminders", "calendar", "contacts"]
        }
    }

    /// Whether this specialist should see every registered tool (catch-all).
    var seesAllTools: Bool { self == .generalist }

    /// Focused persona injected as the sub-agent's system prompt.
    var systemPrompt: String {
        switch self {
        case .researcher:
            return """
            You are the Researcher sub-agent. [[SUBAGENT:researcher]]
            You handle ONE step of a larger plan: gather facts and current \
            information. Use the web_search tool for anything time-sensitive or \
            factual you are unsure of, and the datetime tool when you need the \
            current date or time. Report concise findings. Do not attempt work \
            outside your assigned step.
            """
        case .coder:
            return """
            You are the Coder sub-agent. [[SUBAGENT:coder]]
            You handle ONE step of a larger plan: write, explain, or debug code. \
            Produce correct, runnable code with a brief explanation. Use the \
            calculator for arithmetic; escalate to Gemini only for large or \
            complex generation. Stay focused on your assigned step.
            """
        case .mathematician:
            return """
            You are the Math sub-agent. [[SUBAGENT:mathematician]]
            You handle ONE step of a larger plan: solve quantitative problems. \
            Use the calculator tool for any non-trivial arithmetic and the \
            unit_converter tool for unit conversions. State the final result \
            clearly. Stay focused on your assigned step.
            """
        case .writer:
            return """
            You are the Writer sub-agent. [[SUBAGENT:writer]]
            You handle ONE step of a larger plan: produce clear, well-structured \
            prose (emails, summaries, essays, explanations). Match the requested \
            tone and length. You may escalate to Gemini for very long or complex \
            pieces. Stay focused on your assigned step.
            """
        case .generalist:
            return """
            You are a capable general-purpose sub-agent. [[SUBAGENT:generalist]]
            You handle ONE step of a larger plan. Use any available tool when it \
            helps, and be concise and accurate. Stay focused on your assigned step.
            """
        }
    }

    /// Lenient parse from the planner's free-text label; unknown → generalist.
    static func from(label: String?) -> Specialist {
        guard let label = label?.lowercased().trimmingCharacters(in: .whitespaces),
              !label.isEmpty else { return .generalist }
        if let exact = Specialist(rawValue: label) { return exact }
        // Tolerate near-misses the model might emit.
        if label.contains("research") || label.contains("search") || label.contains("web") {
            return .researcher
        }
        if label.contains("cod") || label.contains("program") || label.contains("script") {
            return .coder
        }
        if label.contains("math") || label.contains("calc") || label.contains("compute") {
            return .mathematician
        }
        if label.contains("writ") || label.contains("draft") || label.contains("essay") {
            return .writer
        }
        return .generalist
    }
}

// MARK: - Plan

/// A single step in a decomposed plan.
struct PlanStep: Codable, Sendable, Identifiable {
    let id: Int                 // 1-based ordinal
    let description: String     // natural-language instruction for the sub-agent
    let specialist: Specialist
    let toolHint: String?       // advisory only

    init(id: Int, description: String, specialist: Specialist, toolHint: String? = nil) {
        self.id = id
        self.description = description
        self.specialist = specialist
        self.toolHint = toolHint
    }
}

/// An ordered decomposition of a complex request.
struct Plan: Codable, Sendable {
    let steps: [PlanStep]

    /// A degenerate one-step plan handled by the generalist — equivalent to the
    /// app's pre-existing single-shot ReAct behavior. Used as the graceful
    /// fallback whenever planning fails.
    static func singleStep(_ goal: String) -> Plan {
        Plan(steps: [PlanStep(id: 1, description: goal, specialist: .generalist)])
    }

    var isSingleStep: Bool { steps.count <= 1 }

    /// One-line summary for the reasoning trace, e.g.
    /// "1. search news (researcher) · 2. summarize (writer)".
    var traceSummary: String {
        steps.map { "\($0.id). \($0.description.prefix(48)) (\($0.specialist.rawValue))" }
            .joined(separator: " · ")
    }
}

// MARK: - Scratchpad

/// Append-only log of completed step results, threaded through the plan so each
/// sub-agent can build on what came before. Rendered into the prompt trimmed to
/// a character budget (keeping the most-recent results) to protect the context
/// window.
struct Scratchpad: Sendable {
    private(set) var entries: [(step: Int, specialist: Specialist, result: String)] = []

    mutating func record(step: Int, specialist: Specialist, result: String) {
        entries.append((step, specialist, result))
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Rendered context block, newest entries prioritized within `budget` chars.
    func rendered(budget: Int = 2000) -> String {
        guard !entries.isEmpty else { return "" }
        var lines: [String] = []
        var used = 0
        for entry in entries.reversed() {
            let line = "[Step \(entry.step) · \(entry.specialist.rawValue)] \(entry.result.trimmingCharacters(in: .whitespacesAndNewlines))"
            if used + line.count > budget, !lines.isEmpty { break }
            lines.append(line)
            used += line.count
        }
        let body = lines.reversed().joined(separator: "\n")
        return "Results from previous steps:\n\(body)"
    }
}
