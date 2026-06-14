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
        // Look for JSON object with "tool_call" key anywhere in the text
        // Handle code blocks
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Find the first { ... } block that contains "tool_call"
        guard let startRange = cleaned.range(of: "{"),
              cleaned.contains("\"tool_call\"") else { return nil }

        // Find matching closing brace
        var depth = 0
        var endIndex: String.Index? = nil
        var started = false

        for (i, char) in cleaned.enumerated() {
            let idx = cleaned.index(cleaned.startIndex, offsetBy: i)
            if char == "{" {
                depth += 1
                started = true
            } else if char == "}" {
                depth -= 1
                if started && depth == 0 {
                    endIndex = cleaned.index(after: idx)
                    break
                }
            }
        }

        // No balanced closing brace (e.g. truncated by maxNewTokens) — the
        // tool call isn't complete, so don't slice an invalid range; bail.
        guard let endIndex else { return nil }

        let jsonString = String(cleaned[startRange.lowerBound..<endIndex])
        guard let data = jsonString.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(ParsedToolCall.self, from: data) else {
            return nil
        }

        return ToolCallInfo(
            name: parsed.tool_call.name,
            arguments: parsed.tool_call.arguments
        )
    }
}
