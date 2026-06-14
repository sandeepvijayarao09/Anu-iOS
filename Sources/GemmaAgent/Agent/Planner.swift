import Foundation

// MARK: - Planner

/// Decomposes a complex request into an ordered `Plan` with a single model call.
///
/// The planner runs at a low temperature for JSON discipline and emits no tool
/// calls — it only produces the plan. Any failure to produce a usable plan
/// degrades gracefully to `Plan.singleStep`, which the executor runs exactly
/// like the app's original single-shot ReAct loop.
@MainActor
struct Planner {
    let model: any LocalLanguageModel
    /// Specialists the planner is told it can dispatch to.
    var availableSpecialists: [Specialist] = Specialist.allCases

    /// Maximum steps honored — bounds total on-device latency.
    static let maxSteps = 6

    func makePlan(goal: String, memoryContext: String? = nil) async -> Plan {
        let prompt = GemmaChatTemplate.format(
            messages: [.user(goal)],
            tools: [],
            memoryContext: memoryContext,
            systemPromptOverride: systemPrompt
        )

        var raw = ""
        do {
            let stream = try await model.generate(prompt: prompt, config: .deterministic)
            for await token in stream {
                if Task.isCancelled { break }
                raw += token
            }
        } catch {
            return .singleStep(goal)
        }
        guard !Task.isCancelled else { return .singleStep(goal) }

        let plan = PlanParser.parse(raw, goal: goal)
        // Cap step count to keep latency bounded.
        guard plan.steps.count > Self.maxSteps else { return plan }
        return Plan(steps: Array(plan.steps.prefix(Self.maxSteps)))
    }

    private var systemPrompt: String {
        let specialistList = availableSpecialists.map(\.rawValue).joined(separator: ", ")
        return """
        You are the Planner. [[PLANNER]]
        Break the user's request into the SMALLEST number of ordered steps that \
        will accomplish it, then assign each step to the most suitable specialist.

        Available specialists: \(specialistList).
        - researcher: finds facts / current info (web search, date/time).
        - coder: writes or debugs code.
        - mathematician: calculations and unit conversions.
        - writer: emails, summaries, essays, explanations.
        - generalist: anything else, or simple one-off tasks.

        Rules:
        - Use as FEW steps as possible. A simple request is ONE step.
        - Each step must be a concrete instruction a single specialist can do.
        - Later steps may rely on earlier steps' results.

        Respond with ONLY this JSON, nothing else:
        {"plan": [
          {"step": 1, "description": "<what to do>", "specialist": "<name>", "tool_hint": "<optional tool>"}
        ]}
        """
    }
}

// MARK: - Plan parser

/// Tolerant parser for the planner's JSON output. Never throws: anything it
/// can't turn into a usable multi-step plan collapses to `Plan.singleStep`.
enum PlanParser {

    static func parse(_ raw: String, goal: String) -> Plan {
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Preferred shape: an object containing a "plan" array.
        if let object = firstBalancedObject(in: cleaned, mustContain: "plan"),
           let data = object.data(using: .utf8),
           let wrapper = try? JSONDecoder().decode(RawPlan.self, from: data) {
            let plan = build(from: wrapper.plan)
            if !plan.steps.isEmpty { return plan }
        }

        // Fallback shape: a bare top-level array of steps.
        if let array = firstBalancedArray(in: cleaned),
           let data = array.data(using: .utf8),
           let steps = try? JSONDecoder().decode([RawStep].self, from: data) {
            let plan = build(from: steps)
            if !plan.steps.isEmpty { return plan }
        }

        return .singleStep(goal)
    }

    // MARK: Raw decode shapes

    private struct RawPlan: Decodable { let plan: [RawStep] }

    private struct RawStep: Decodable {
        let step: Int?
        let description: String?
        let specialist: String?
        let tool_hint: String?
    }

    private static func build(from raw: [RawStep]) -> Plan {
        var steps: [PlanStep] = []
        for (i, r) in raw.enumerated() {
            let desc = (r.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !desc.isEmpty else { continue }
            let hint = r.tool_hint?.trimmingCharacters(in: .whitespacesAndNewlines)
            steps.append(PlanStep(
                id: r.step ?? (i + 1),
                description: desc,
                specialist: Specialist.from(label: r.specialist),
                toolHint: (hint?.isEmpty == false) ? hint : nil
            ))
        }
        return Plan(steps: steps)
    }

    // MARK: Balanced-delimiter extraction (mirrors ResponseParser)

    /// First balanced `{ ... }` block that contains `needle`, or nil.
    static func firstBalancedObject(in text: String, mustContain needle: String) -> String? {
        guard text.contains(needle) else { return nil }
        return firstBalanced(in: text, open: "{", close: "}")
    }

    /// First balanced `[ ... ]` block, or nil.
    static func firstBalancedArray(in text: String) -> String? {
        firstBalanced(in: text, open: "[", close: "]")
    }

    private static func firstBalanced(in text: String, open: Character, close: Character) -> String? {
        guard let startRange = text.range(of: String(open)) else { return nil }
        var depth = 0
        var started = false
        var end: String.Index? = nil
        var i = startRange.lowerBound
        while i < text.endIndex {
            let c = text[i]
            if c == open {
                depth += 1
                started = true
            } else if c == close {
                depth -= 1
                if started && depth == 0 {
                    end = text.index(after: i)
                    break
                }
            }
            i = text.index(after: i)
        }
        guard let end else { return nil } // unbalanced (e.g. truncated) → bail
        return String(text[startRange.lowerBound..<end])
    }
}
