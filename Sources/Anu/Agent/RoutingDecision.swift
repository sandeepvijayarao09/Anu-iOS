import Foundation

// MARK: - Routing Decision

enum RoutingDecision: Sendable {
    case answerLocally(String)
    case callTool(ToolCallInfo)
    case escalateToGemini(task: String, context: String)
}

// MARK: - Response Parser

/// Parses raw model output into a routing decision
enum ResponseParser {

    static func parse(_ rawOutput: String) -> RoutingDecision {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to extract a JSON tool call from the output
        if let toolCall = extractToolCall(from: trimmed) {
            if toolCall.name == "escalate_to_gemini" {
                let task = toolCall.arguments["task"]?.stringValue ?? trimmed
                let context = toolCall.arguments["context"]?.stringValue ?? ""
                return .escalateToGemini(task: task, context: context)
            }
            return .callTool(toolCall)
        }

        // No tool call found — treat as direct answer
        return .answerLocally(trimmed)
    }

    static func extractToolCall(from text: String) -> ToolCallInfo? {
        // Look for a JSON object with a "tool_call" key anywhere in the text.
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleaned.contains("\"tool_call\"") else { return nil }

        // Scan every top-level balanced object (string-aware) and return the
        // first that decodes to a tool call. This handles braces that appear
        // inside string values (which used to close the object early) and any
        // prose the model emits before the JSON. A truncated/unbalanced tail
        // simply produces no span, so we bail rather than slice garbage.
        for span in balancedSpans(in: cleaned, open: "{", close: "}") {
            guard span.contains("\"tool_call\""),
                  let data = span.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(ParsedToolCall.self, from: data)
            else { continue }
            return ToolCallInfo(
                name: parsed.tool_call.name,
                arguments: parsed.tool_call.arguments
            )
        }
        return nil
    }

    /// Every top-level balanced `open … close` span in `text`, ignoring
    /// delimiters inside JSON string literals (so a brace within a string value
    /// doesn't close the object early). Unbalanced trailing input (e.g. output
    /// truncated by maxNewTokens) yields no span. Shared by `PlanParser`.
    static func balancedSpans(in text: String, open: Character, close: Character) -> [String] {
        var spans: [String] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == open {
                if depth == 0 { start = i }
                depth += 1
            } else if c == close, depth > 0 {
                depth -= 1
                if depth == 0, let s = start {
                    spans.append(String(text[s...i]))
                    start = nil
                }
            }
            i = text.index(after: i)
        }
        return spans
    }
}
