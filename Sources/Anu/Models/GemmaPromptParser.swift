import Foundation

// MARK: - Gemma prompt parser (pure, testable)
//
// Anu's orchestrator hands every backend a fully Gemma-templated prompt
// (`<start_of_turn>user … <end_of_turn>` …). The iOS MediaPipe backend wants
// exactly that (it's a raw text-completion engine). LiteRT-LM's `Conversation`,
// by contrast, does its OWN chat templating and history management — feeding it
// the already-templated string would double-wrap it. So the macOS LiteRT-LM
// backend parses the templated prompt back into discrete turns and drives the
// Conversation natively. This parsing is deterministic and unit-tested here,
// independent of the (macOS-only) LiteRT-LM package.

struct GemmaTurn: Equatable {
    enum Role: Equatable { case user, model }
    let role: Role
    let content: String
}

enum GemmaPromptParser {
    /// Parse a `GemmaChatTemplate`-formatted prompt into ordered turns. The
    /// trailing `<start_of_turn>model\n` generation cue (an open turn with no
    /// `<end_of_turn>`) is intentionally dropped — it's the prompt to generate,
    /// not a completed turn. The system/persona that Anu folds into the first
    /// user turn rides along inside that turn's content (Gemma has no system
    /// role), which is exactly how a Conversation should receive it.
    static func parse(_ prompt: String) -> [GemmaTurn] {
        var turns: [GemmaTurn] = []
        for part in prompt.components(separatedBy: "<start_of_turn>") where !part.isEmpty {
            let role: GemmaTurn.Role
            let body: Substring
            if part.hasPrefix("user\n") {
                role = .user
                body = part.dropFirst("user\n".count)
            } else if part.hasPrefix("model\n") {
                role = .model
                body = part.dropFirst("model\n".count)
            } else {
                continue
            }
            guard let end = body.range(of: "<end_of_turn>") else {
                continue   // open generation cue — no completed content
            }
            turns.append(GemmaTurn(role: role, content: String(body[body.startIndex..<end.lowerBound])))
        }
        return turns
    }

    /// The newest user turn — the message a stateful `Conversation` should be
    /// sent this turn (it already holds the earlier turns in its own history).
    static func latestUserTurn(_ prompt: String) -> String? {
        parse(prompt).last(where: { $0.role == .user })?.content
    }
}
