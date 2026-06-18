import Foundation

// MARK: - Critic (reflection / self-verify)

/// Reviews a synthesized draft answer against the original goal and either
/// approves it or asks for ONE revision. Bounded by design: the executor calls
/// `review` at most once and honors at most one `.revise`, so there is no
/// reflection loop. Any parse ambiguity defaults to `.approved` — the critic
/// can never block a usable answer.
@MainActor
struct Critic {
    let model: any LocalLanguageModel

    enum Verdict: Sendable, Equatable {
        case approved
        case revise(instruction: String)
    }

    func review(goal: String, draft: String, scratchpad: Scratchpad) async -> Verdict {
        let context = scratchpad.isEmpty ? "" : "\n\n\(scratchpad.rendered())"
        let userTurn = """
        Original request:
        \(goal)\(context)

        Proposed answer:
        \(draft)
        """
        let prompt = GemmaChatTemplate.format(
            messages: [.user(userTurn)],
            tools: [],
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
            return .approved
        }
        guard !Task.isCancelled else { return .approved }

        return Self.parse(raw)
    }

    /// Lenient verdict parser. Defaults to `.approved`. Pure — callable off the
    /// main actor (used directly in tests).
    nonisolated static func parse(_ raw: String) -> Verdict {
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")

        if let object = PlanParser.firstBalancedObject(in: cleaned, mustContain: "verdict"),
           let data = object.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(RawVerdict.self, from: data) {
            if parsed.verdict.lowercased().hasPrefix("approve") {
                return .approved
            }
            let instruction = parsed.instruction?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let instruction, !instruction.isEmpty {
                return .revise(instruction: instruction)
            }
            // "revise" with no actionable instruction is not worth a round-trip.
            return .approved
        }
        return .approved
    }

    private struct RawVerdict: Decodable {
        let verdict: String
        let instruction: String?
    }

    private var systemPrompt: String {
        """
        You are the Critic. [[CRITIC]]
        Judge whether the proposed answer fully and correctly addresses the \
        original request. Be strict about completeness and accuracy, but do not \
        nitpick style.

        Respond with ONLY this JSON, nothing else:
        - If the answer is good: {"verdict": "approved"}
        - If it needs fixing: {"verdict": "revise", "instruction": "<one concrete, actionable fix>"}
        """
    }
}
