import Foundation

/// Gemma chat template formatter
struct GemmaChatTemplate {

    /// Who Anu is and how it talks (part of `instructions`).
    static let chatPersona = """
    You are Anu, a friendly on-device AI companion. Your vibe is warm, \
    casual, and human — like texting a clever friend.

    Style:
    - Answer the question first, accurately. Keep replies short: one to three \
    sentences unless more is genuinely needed.
    - Plain, everyday language. Contractions are welcome.
    - No flattery ("Great question!", "Those are gorgeous!"), and no follow-up \
    question unless you need one to help.
    - No headers or bullet lists in casual chat; just talk. When asked for a \
    list, steps, or action items, give a short bulleted list.

    Pictures:
    - Describe only what is actually visible; never invent details.
    - When asked to identify something (a plant, animal, product, place), give \
    your best answer with its distinguishing features, and say plainly if \
    you're not sure or if it could be something else.
    - Read any text in the picture exactly as written.
    """

    /// A chat turn: the same prompt as an agent turn, without tools. Both
    /// share one opening and one history shape, so the engine keeps reading
    /// on when the router moves between them (rebuilding re-read the chat).
    /// `memoryContext` is the NotebookLM-style grounded-sources block.
    static func formatChat(messages: [AgentMessage], memoryContext: String? = nil) -> String {
        format(messages: messages, tools: [], memoryContext: memoryContext)
    }

    /// - Parameter systemPromptOverride: replaces the default ReAct system
    ///   prompt (used by sub-agents / planner / critic for their own personas).
    ///   When set AND `tools` is non-empty, the tool-call protocol block is
    ///   still appended so the override can call its tool subset.
    static func format(
        messages: [AgentMessage],
        tools: [any Tool],
        memoryContext: String? = nil,
        systemPromptOverride: String? = nil,
        now: Date = Date()
    ) -> String {
        var prompt = ""

        // Gemma has no system role — its chat template folds system
        // instructions into the first user turn, so we do the same.
        // The first turn holds only what stays the same for the whole chat,
        // so the engine can keep reading on from it. What changes message to
        // message (the tools chosen for it, the memory relevant to it) goes
        // with the newest message.
        let systemContent = systemPromptOverride ?? instructions
        // The clock goes with every message: left without it, the model
        // invents a date (seen in the benchmark: "Tuesday, October 29, 2024").
        let clock = systemPromptOverride == nil ? "Now: " + AnuDate.spoken.string(from: now) + "." : nil
        let turnContext = [clock, toolProtocolBlock(tools: tools).trimmingCharacters(in: .whitespacesAndNewlines), memoryContext]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let newest = messages.lastIndex(where: { $0.role == .user })
        var systemPending = true
        // Anu's own chats open the same way every time, so the engine can read
        // the opening before the first message arrives (`warmUpPrompt`).
        if systemPromptOverride == nil {
            prompt = opening + "<start_of_turn>model\n\(openingReply)<end_of_turn>\n"
            systemPending = false
        }

        for (index, message) in messages.enumerated() {
            switch message.role {
            case .user:
                let content = index == newest ? withTurnContext(message.content, turnContext) : message.content
                if systemPending {
                    // The first message is always labelled, newest or not, so
                    // the opening reads the same on every turn.
                    let first = index == newest ? content : messageHeader + content
                    prompt += "<start_of_turn>user\n\(systemContent)\n\n\(first)<end_of_turn>\n"
                    systemPending = false
                } else {
                    prompt += "<start_of_turn>user\n\(content)<end_of_turn>\n"
                }
            case .assistant:
                prompt += "<start_of_turn>model\n\(message.content)<end_of_turn>\n"
            case .toolCall:
                // Tool calls are embedded in assistant turns
                if let tc = message.toolCall {
                    let json = (try? JSONEncoder().encode(tc)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    prompt += "<start_of_turn>model\n\(json)<end_of_turn>\n"
                }
            case .toolResult:
                // Tool results come back as a user turn (Gemma has no tool role)
                prompt += "<start_of_turn>user\nTool result:\n\(message.content)<end_of_turn>\n"
            case .system:
                break
            }
        }

        // Start model response
        prompt += "<start_of_turn>model\n"
        return prompt
    }

    // MARK: The opening

    /// Every Anu chat starts with the instructions and this short exchange, the
    /// same for each chat, so the engine reads it once, ahead of time, instead
    /// of with the first message (about 580 tokens, 15 s on the simulator's CPU
    /// before the first word, TurnLatencyTests 2026-11-14).
    static let openingCue = "Reply with only: Ready."
    static let openingReply = "Ready."
    static var opening: String { "<start_of_turn>user\n\(instructions)\n\n\(openingCue)<end_of_turn>\n" }
    /// The opening on its own, for the engine to read while nobody waits.
    static var warmUpPrompt: String { opening + "<start_of_turn>model\n" }

    /// A user turn as the chat keeps it: no per-message context, no label.
    /// Tells chats apart, now that they all open the same way.
    static func plainTurn(_ turn: String) -> String {
        let bare = withoutTurnContext(turn)
        return bare.hasPrefix(messageHeader) ? String(bare.dropFirst(messageHeader.count)) : bare
    }

    static let contextHeader = "Context for this message:\n"
    /// Labels the user's words, so a short command ("Reply with only YES")
    /// can't read as part of the instructions or context before it (seen in
    /// the benchmark: "I'm ready to help!").
    static let messageHeader = "The user's message:\n"

    /// The newest message, with the context for answering it (tools, memory).
    static func withTurnContext(_ message: String, _ context: String?) -> String {
        guard let context, !context.isEmpty else { return messageHeader + message }
        return contextHeader + context + "\n\n" + messageHeader + message
    }

    /// A turn without its per-message context: the same text whether it is
    /// the newest message or an older one. The engine compares openings by it.
    static func withoutTurnContext(_ turn: String) -> String {
        guard let start = turn.range(of: contextHeader),
              let end = turn.range(of: messageHeader, range: start.upperBound..<turn.endIndex) else { return turn }
        return String(turn[..<start.lowerBound] + turn[end.lowerBound...])
    }

    /// The tool catalogue + JSON tool-call protocol. Shared by the default
    /// ReAct system prompt and any `systemPromptOverride` that calls tools.
    /// Empty string when there are no tools.
    static func toolProtocolBlock(tools: [any Tool]) -> String {
        guard !tools.isEmpty else { return "" }
        var block = "\n\nAvailable tools:\n"
        for tool in tools {
            block += "- **\(tool.name)**: \(tool.description)\n"
            if let params = tool.parameters,
               let data = try? JSONEncoder().encode(params),
               let json = String(data: data, encoding: .utf8) {
                block += "  Parameters: \(json)\n"
            }
        }
        block += "\n" + toolCallFormat + "\n"
        return block
    }

    /// How to call a tool: closes every tool list.
    static let toolCallFormat = """
    To call a tool, output a JSON block on its own line:
    ```json
    {"tool_call": {"name": "tool_name", "arguments": {"arg1": "value1"}}}
    ```
    Wait for the tool result before continuing.
    """

    // MARK: Telling a live conversation only what's new

    /// The newest message with the tools a live conversation was already given
    /// named, not described again; `known` gains the ones described here. The
    /// engine still holds the earlier description, and re-reading every tool
    /// cost hundreds of tokens a turn (TurnLatencyTests, 2026-11-14).
    static func describingNewToolsOnly(_ turn: String, known: inout Set<String>) -> String {
        guard let list = turn.range(of: "Available tools:\n"),
              let format = turn.range(of: toolCallFormat, range: list.upperBound..<turn.endIndex) else { return turn }
        var entries: [(name: String, text: String)] = []
        for line in turn[list.upperBound..<format.lowerBound].split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("- **"), let end = line.range(of: "**:") {
                let name = String(line[line.index(line.startIndex, offsetBy: 4)..<end.lowerBound])
                entries.append((name, line + "\n"))
            } else if !line.isEmpty, !entries.isEmpty {
                entries[entries.count - 1].text += line + "\n"
            }
        }
        let formatKnown = known.contains(toolCallFormat)
        let fresh = entries.filter { !known.contains($0.name) }
        let earlier = entries.filter { known.contains($0.name) }.map(\.name)
        known.formUnion(entries.map(\.name))
        known.insert(toolCallFormat)
        if fresh.count == entries.count && !formatKnown { return turn }

        var block = ""
        if !fresh.isEmpty { block += "Available tools:\n" + fresh.map(\.text).joined() }
        if !earlier.isEmpty {
            block += (fresh.isEmpty ? "Tools for this message" : "Also for this message")
                + " (described earlier): " + earlier.joined(separator: ", ") + "."
        }
        if !formatKnown { block += "\n" + toolCallFormat }
        return turn.replacingCharacters(in: list.lowerBound..<format.upperBound,
                                        with: block.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Turns a live conversation missed, because they were answered without
    /// the model (a sum, a timer), told with the next message so it reads on
    /// instead of starting over.
    static func withMissedTurns(_ missed: [(fromUser: Bool, text: String)], _ message: String) -> String {
        guard !missed.isEmpty else { return message }
        let lines = missed.map { ($0.fromUser ? "User: " : "Anu: ") + $0.text }
        return "Meanwhile, answered without you:\n" + lines.joined(separator: "\n") + "\n\n" + message
    }

    /// How to act: shared by every turn, so it can sit in the stable opening.
    static let toolGuidance = """
    How you work (ReAct): reason about what the user needs, then either answer \
    directly or, when tools are listed with the message, call one; then read \
    its result and continue.

    - Simple questions, math you can do, facts you know, short tasks: just answer.
    - Real-time information, or when you're unsure: the web_search tool.
    - Long writing, detailed code or hard reasoning: the escalate_to_gemini tool.
    - Arithmetic: the calculator tool.
    - When you have the final answer, state it plainly without a tool call.

    When the user asks you to DO something, do it with a tool instead of only \
    describing it:
    - Reminders, to-dos, shopping lists → reminders tool. Calendar, scheduling, \
    "am I free" → calendar tool.
    - Someone's phone number or email → contacts tool. The time or date → datetime tool.
    - Calling, texting or emailing someone → contact_action tool (a name, or a number/email).
    - A timer ("in 10 minutes") or alarm ("at 7am") → set_timer tool.
    - Directions, music, or opening another app → open_app tool (see its URL patterns).
    - One of the user's saved automations → run_shortcut tool.
    - Relative times like "tomorrow at 5pm", "tonight" or "in 10 minutes" can be \
    passed straight through as the date; don't work out an absolute date.
    """

    /// Anu's instructions for every turn: who it is and how it acts.
    static let instructions = chatPersona + "\n\n" + toolGuidance

}
