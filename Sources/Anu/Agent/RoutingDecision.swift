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

        guard cleaned.contains("\"tool_call\"") else {
            return extractNativeToolCall(from: cleaned)
        }

        // Scan every top-level balanced object (string-aware) and return the
        // first that decodes to a tool call. This handles braces that appear
        // inside string values (which used to close the object early) and any
        // prose the model emits before the JSON. A truncated/unbalanced tail
        // simply produces no span, so we bail rather than slice garbage.
        for span in balancedSpans(in: cleaned, open: "{", close: "}") {
            guard span.contains("\"tool_call\""),
                  let parsed = decodeLoosely(ParsedToolCall.self, from: span)
            else { continue }
            return ToolCallInfo(
                name: parsed.tool_call.name,
                arguments: parsed.tool_call.arguments
            )
        }
        return extractNativeToolCall(from: cleaned)
    }

    /// Gemma 4 frequently ignores the JSON contract in the prompt and emits
    /// its own trained-in call syntax instead:
    ///
    ///     <|tool_call>call:calculator{"expression":"0.18 * 47.50"}<tool_call|>
    ///
    /// Unrecognised, that markup fell through to `.answerLocally` and rendered
    /// in the chat as the assistant's reply while the tool never ran. Consulted
    /// only after the documented JSON form fails, so the happy path is
    /// unchanged.
    static func extractNativeToolCall(from text: String) -> ToolCallInfo? {
        // Pipe placement varies between builds; take whichever opener comes first.
        let openers = ["<|tool_call>", "<|tool_call|>", "<tool_call>"]
        guard let opener = openers
            .compactMap({ text.range(of: $0) })
            .min(by: { $0.lowerBound < $1.lowerBound })
        else { return nil }

        var body = String(text[opener.upperBound...])
        for closer in ["<tool_call|>", "<|tool_call|>", "</tool_call>", "<|/tool_call|>"] {
            if let found = body.range(of: closer) {
                body = String(body[..<found.lowerBound])
                break
            }
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("call:") { body = String(body.dropFirst(5)) }

        // The name runs from here to the start of the argument object.
        guard let brace = body.firstIndex(of: "{") else { return nil }
        let name = body[..<brace]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n"))
        guard !name.isEmpty else { return nil }

        // Reuse the string-aware scanner so braces inside argument values
        // don't truncate the object.
        // Repair before scanning: single-quoted strings would otherwise throw
        // off the string-aware brace tracking too.
        let repaired = repairLooseJSON(String(body[brace...]))
        guard let span = balancedSpans(in: repaired, open: "{", close: "}").first,
              let arguments = decodeLoosely(JSONValue.self, from: span)
        else { return nil }

        return ToolCallInfo(name: name, arguments: arguments)
    }

    /// Decodes strict JSON, retrying once on a repaired copy. Valid JSON never
    /// reaches the repair pass, so well-formed output is unaffected.
    static func decodeLoosely<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        if let data = json.data(using: .utf8),
           let value = try? JSONDecoder().decode(type, from: data) {
            return value
        }
        guard let data = repairLooseJSON(json).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Gemma emits JavaScript-style object literals as often as strict JSON —
    /// bare keys (`{expression: "0.18 * 47.50"}`) and single-quoted strings.
    /// `JSONDecoder` rejects both, which left real tool calls unparsed and
    /// leaked the markup into the chat as the assistant's reply. This quotes
    /// bare keys and normalises quote characters; anything already valid comes
    /// through byte-identical.
    static func repairLooseJSON(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count + 16)

        var inString = false
        var delimiter: Character = "\""
        var escaped = false
        // True immediately after `{` or `,` — the only places a key can start.
        var atKeyPosition = false
        var index = text.startIndex

        while index < text.endIndex {
            let char = text[index]

            if inString {
                if escaped {
                    out.append(char)
                    escaped = false
                } else if char == "\\" {
                    out.append(char)
                    escaped = true
                } else if char == delimiter {
                    out.append("\"")            // always close with a JSON quote
                    inString = false
                } else if char == "\"" {
                    out.append("\\\"")           // a bare quote inside '…' must be escaped
                } else {
                    out.append(char)
                }
                index = text.index(after: index)
                continue
            }

            switch char {
            case "{", ",":
                atKeyPosition = true
                out.append(char)
            case ":":
                atKeyPosition = false
                out.append(char)
            case "'", "\"":
                delimiter = char
                inString = true
                out.append("\"")
                atKeyPosition = false
            default:
                if char.isWhitespace {
                    out.append(char)
                } else if atKeyPosition, char.isLetter || char == "_" {
                    // Read the bare identifier, then confirm it really is a key
                    // (next non-space character is a colon) before quoting it.
                    var end = index
                    while end < text.endIndex,
                          text[end].isLetter || text[end].isNumber || text[end] == "_" {
                        end = text.index(after: end)
                    }
                    let identifier = String(text[index..<end])
                    var probe = end
                    while probe < text.endIndex, text[probe].isWhitespace {
                        probe = text.index(after: probe)
                    }
                    if probe < text.endIndex, text[probe] == ":" {
                        out.append("\"\(identifier)\"")
                    } else {
                        out.append(identifier)   // `true`, `null`, a number — leave alone
                    }
                    atKeyPosition = false
                    index = end
                    continue
                } else {
                    atKeyPosition = false
                    out.append(char)
                }
            }
            index = text.index(after: index)
        }
        return out
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
