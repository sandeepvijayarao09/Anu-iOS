import Foundation

/// Protocol for text tokenizers
protocol Tokenizer: Sendable {
    func encode(_ text: String) -> [Int]
    func decode(_ tokens: [Int]) -> String
    var bosTokenId: Int { get }
    var eosTokenId: Int { get }
    var padTokenId: Int { get }
}

/// Gemma chat template formatter
struct GemmaChatTemplate {

    /// Persona for casual conversation (chat mode) — no tool protocol,
    /// small prefill, warm tone.
    static let chatPersona = """
    You are Gemma, a friendly on-device AI companion. Your vibe is warm, \
    casual, and human — like texting a clever friend.

    Style:
    - Keep replies short: one to three sentences unless more is genuinely needed.
    - Plain, everyday language. Contractions are welcome.
    - Be encouraging and curious; a light follow-up question is nice when it fits.
    - No headers or bullet lists in casual chat; just talk.
    """

    /// Chat-mode prompt: persona folded into the first user turn, no tools.
    /// `memoryContext` is the NotebookLM-style grounded-sources block.
    static func formatChat(messages: [AgentMessage], memoryContext: String? = nil) -> String {
        var prompt = ""
        var personaPending = true
        let header = memoryContext.map { "\(chatPersona)\n\n\($0)" } ?? chatPersona

        for message in messages {
            switch message.role {
            case .user:
                if personaPending {
                    prompt += "<start_of_turn>user\n\(header)\n\n\(message.content)<end_of_turn>\n"
                    personaPending = false
                } else {
                    prompt += "<start_of_turn>user\n\(message.content)<end_of_turn>\n"
                }
            case .assistant:
                prompt += "<start_of_turn>model\n\(message.content)<end_of_turn>\n"
            case .toolCall, .toolResult, .system:
                break // not part of casual chat
            }
        }

        prompt += "<start_of_turn>model\n"
        return prompt
    }

    /// - Parameter systemPromptOverride: replaces the default ReAct system
    ///   prompt (used by sub-agents / planner / critic for their own personas).
    ///   When set AND `tools` is non-empty, the tool-call protocol block is
    ///   still appended so the override can call its tool subset.
    static func format(
        messages: [AgentMessage],
        tools: [any Tool],
        memoryContext: String? = nil,
        systemPromptOverride: String? = nil
    ) -> String {
        var prompt = ""

        // Gemma has no system role — its chat template folds system
        // instructions into the first user turn, so we do the same.
        var systemContent: String
        if let systemPromptOverride {
            systemContent = systemPromptOverride
            if !tools.isEmpty { systemContent += toolProtocolBlock(tools: tools) }
        } else {
            systemContent = buildSystemPrompt(tools: tools)
        }
        if let memoryContext { systemContent += "\n\n" + memoryContext }
        var systemPending = true

        for message in messages {
            switch message.role {
            case .user:
                if systemPending {
                    prompt += "<start_of_turn>user\n\(systemContent)\n\n\(message.content)<end_of_turn>\n"
                    systemPending = false
                } else {
                    prompt += "<start_of_turn>user\n\(message.content)<end_of_turn>\n"
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
        block += """

To call a tool, output a JSON block on its own line:
```json
{"tool_call": {"name": "tool_name", "arguments": {"arg1": "value1"}}}
```
Wait for the tool result before continuing.
"""
        return block
    }

    static func buildSystemPrompt(tools: [any Tool]) -> String {
        let toolDescriptions = toolProtocolBlock(tools: tools)

        return """
You are GemmaAgent, an intelligent agentic AI assistant running on-device using the Gemma 4B model.

You operate in a ReAct (Reason, Act, Observe) loop:
1. **Reason**: Think through what the user needs.
2. **Act**: Either answer directly OR call a tool using the JSON format below.
3. **Observe**: Review tool results and continue reasoning.

Guidelines:
- For simple questions, math, factual recall, or short tasks: answer directly.
- For web search, real-time information, or when you're uncertain: use the web_search tool.
- For complex reasoning, detailed code generation, long-form writing, or tasks needing more capability: use the escalate_to_gemini tool.
- For arithmetic calculations: use the calculator tool.
- Always be concise and helpful.
- When you have a final answer, just state it clearly without tool calls.
\(toolDescriptions)
"""
    }
}

/// Crude character-level fallback used only when tokenizer.json is
/// missing from the bundle (Core ML path).
final class FallbackTokenizer: Tokenizer {
    let bosTokenId: Int = 2
    let eosTokenId: Int = 1
    let padTokenId: Int = 0

    func encode(_ text: String) -> [Int] {
        // Character-level approximation: each scalar becomes its codepoint
        return text.unicodeScalars.map { Int($0.value) }
    }

    func decode(_ tokens: [Int]) -> String {
        // Reverse: convert token IDs back to characters
        let scalars = tokens.compactMap { Unicode.Scalar($0) }
        return String(String.UnicodeScalarView(scalars))
    }
}
