import Foundation

/// How to feed the next prompt into a stateful inference session.
enum PromptFeed: Equatable {
    /// The session has already consumed a prefix of this prompt — feed only
    /// the new suffix (cheap: no re-prefill of the whole conversation).
    case append(String)
    /// The prompt no longer extends what the session has seen (cleared,
    /// trimmed, or mode-switched conversation) — rebuild the session.
    case reset
}

/// Tracks what a stateful session has consumed so multi-turn conversations
/// can reuse the KV cache instead of re-prefilling the full history each turn.
///
/// Accounting: after a generation, the session internally holds
/// `prompt + response + <end_of_turn>`; the next templated prompt extends
/// exactly that text when the conversation simply continues.
struct SessionContextTracker {
    private(set) var seenText = ""

    func feed(for prompt: String) -> PromptFeed {
        guard !seenText.isEmpty, prompt.hasPrefix(seenText) else { return .reset }
        return .append(String(prompt.dropFirst(seenText.count)))
    }

    mutating func didSend(fullPrompt: String) {
        seenText = fullPrompt
    }

    /// Record the assistant turn the way the chat template will replay it:
    /// trimmed content followed by the end-of-turn marker.
    mutating func didGenerate(_ rawResponse: String) {
        let trimmed = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        seenText += trimmed + "<end_of_turn>\n"
    }

    mutating func reset() {
        seenText = ""
    }
}
