import Foundation

#if DEBUG
/// Deterministic scripted responses for automated tests ONLY.
///
/// Reachable exclusively via the `-scripted_model YES` launch argument that
/// the UI test runner passes — there is no Settings toggle, no silent
/// fallback, and this entire type is compiled out of release builds.
actor ScriptedModel: LocalLanguageModel {
    nonisolated let modelName = "Scripted Test Model"
    private var _isLoaded = false

    func load() async throws {
        try await Task.sleep(nanoseconds: 500_000_000) // simulate load time
        _isLoaded = true
    }

    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String> {
        let response = scriptedResponse(for: prompt)
        let tokens = response.components(separatedBy: " ")

        return AsyncStream<String> { continuation in
            let producer = Task {
                for (i, token) in tokens.enumerated() {
                    if Task.isCancelled { break }
                    // 30 ms a word; "-scripted_slow YES" makes it 400 ms, so a UI
                    // test can stop a run partway through.
                    let pause: UInt64 = UserDefaults.standard.bool(forKey: "scripted_slow") ? 400_000_000 : 30_000_000
                    try? await Task.sleep(nanoseconds: pause)
                    let word = i == 0 ? token : " \(token)"
                    continuation.yield(word)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    private func scriptedResponse(for prompt: String) -> String {
        // Pipeline sentinels are embedded in the planner/critic/synthesizer
        // system prompts (which fold into the first user turn). Detect them
        // across the WHOLE prompt, before the last-user-turn routing below.
        // Sub-agent prompts carry [[SUBAGENT:…]] and deliberately fall through
        // to the normal keyword routing so they still exercise real tool calls.
        if prompt.contains(FactExtractor.sentinel) {
            return Self.scriptedFacts(in: prompt)
        }
        if prompt.contains("[[PLANNER]]") {
            return #"""
            {"plan": [
              {"step": 1, "description": "research the topic", "specialist": "researcher", "tool_hint": "web_search"},
              {"step": 2, "description": "summarize the findings", "specialist": "writer"}
            ]}
            """#
        }
        if prompt.contains("[[CRITIC]]") {
            // Allow tests to force a revision by including "revise" in the goal.
            let lastUser = extractLastTurn(role: "user", from: prompt) ?? ""
            if lastUser.lowercased().contains("please revise") {
                return #"{"verdict": "revise", "instruction": "add a brief conclusion"}"#
            }
            return #"{"verdict": "approved"}"#
        }
        if prompt.contains("[[SYNTH]]") {
            return "Here is the combined final answer based on the previous steps."
        }
        // Escalation router (EscalationRouter): escalate when the user message
        // signals a demanding task, else stay local.
        if prompt.contains("[[ROUTER]]") {
            let lastUser = (extractLastTurn(role: "user", from: prompt) ?? "").lowercased()
            return (lastUser.contains("escalate") || lastUser.contains("complex")) ? "ESCALATE" : "LOCAL"
        }

        // The prompt is the full chat template. Route only on the LAST user turn,
        // otherwise keywords in the system prompt would match every time.
        let lastUserTurn = extractLastTurn(role: "user", from: prompt) ?? ""

        // Tool results come back as user turns prefixed "Tool result:" (Gemma
        // has no tool role). Synthesize a final answer instead of calling the
        // tool again — prevents an infinite ReAct loop.
        if lastUserTurn.hasPrefix("Tool result:") {
            let summary = lastUserTurn
                .dropFirst("Tool result:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(300)
            return "Here's what I found: \(summary)"
        }

        // The FIRST user turn embeds the system prompt as "{system}\n\n{message}"
        // (Gemma has no system role). Route on the actual user message — the
        // final paragraph — or system-prompt keywords would match every time.
        let userMessage = lastUserTurn
            .components(separatedBy: "\n\n").last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? lastUserTurn
        let lower = userMessage.lowercased()

        // Connector verification: when a real MCP tool is available in the prompt
        // and the user mentions "mcp", call it. The model decision is scripted,
        // but the resulting MCP tools/call is a genuine network round-trip.
        if lower.contains("mcp"), let mcpTool = Self.firstMCPToolName(in: prompt) {
            return #"{"tool_call": {"name": "\#(mcpTool)", "arguments": {}}}"#
        }

        // An outward action, for the approval-sheet UI test: "send a text to
        // Mom: running late" → contact_action, which the broker must ask about.
        if lower.contains("send a text") {
            let recipient = userMessage.range(of: " to ", options: .caseInsensitive)
                .map { String(userMessage[$0.upperBound...]) } ?? "Mom"
            let parts = recipient.split(separator: ":", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let contact = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "Mom"
            let message = parts.count > 1 && !parts[1].isEmpty ? parts[1] : "On my way"
            let arguments = JSONValue.object([
                "action": .string("text"), "contact": .string(contact), "message": .string(message),
            ])
            return #"{"tool_call": {"name": "contact_action", "arguments": \#(arguments.canonicalJSON)}}"#
        }

        if lower.contains("calculate") || lower.contains("math") || lower.contains("+") || lower.contains("*") || lower.contains("%") {
            let expr = userMessage
                .components(separatedBy: CharacterSet(charactersIn: "0123456789+-*/.()^ ").inverted)
                .max(by: { $0.count < $1.count })?
                .trimmingCharacters(in: .whitespaces) ?? "2 + 2"
            let safeExpr = expr.isEmpty ? "2 + 2" : expr
            return #"{"tool_call": {"name": "calculator", "arguments": {"expression": "\#(safeExpr)"}}}"#
        }

        if lower.contains("search") || lower.contains("latest") || lower.contains("news") || lower.contains("current") {
            return #"{"tool_call": {"name": "web_search", "arguments": {"query": "\#(userMessage)"}}}"#
        }

        if lower.contains("write") || lower.contains("essay") || lower.contains("code") || lower.contains("complex") {
            return #"{"tool_call": {"name": "escalate_to_gemini", "arguments": {"task": "\#(userMessage)", "context": "Escalated from the scripted test model"}}}"#
        }

        return "Scripted test response: I can demo calculations (try \"calculate 15 * 3\"), web searches (try \"search latest AI news\"), and escalation (try \"write me an essay\")."
    }

    /// Memory extraction (`FactExtractor`): a few fixed patterns, answered in
    /// the extractor's JSON format, so learning runs end to end without a model.
    /// "I'm vegetarian", "my <relation> is <Value>", "I live in <City>",
    /// "I'm moving to <City> …".
    static func scriptedFacts(in prompt: String) -> String {
        guard let start = prompt.range(of: FactExtractor.messageHeader) else { return #"{"facts":[]}"# }
        let rest = prompt[start.upperBound...]
        let message = String(rest[..<(rest.range(of: "<end_of_turn>")?.lowerBound ?? rest.endIndex)])
        var facts: [[String: Any]] = []
        func add(_ predicate: String, _ value: String, _ section: String, _ quote: String) {
            facts.append(["subject": "user", "predicate": predicate, "value": value, "section": section, "quote": quote])
        }
        func match(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) else { return nil }
            return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: message).map { String(message[$0]) } ?? "" }
        }
        if let m = match(#"\bI'?m (?:a )?(vegetarian|vegan)\b"#) { add("diet", m[1].lowercased(), "preferences", m[0]) }
        if let m = match(#"\bI'?m moving to ([A-Z][a-z]+)[^.!?]*"#) { add("lives_in", m[1], "places", m[0]) }
        else if let m = match(#"\bI live in ([A-Z][a-z]+)"#) { add("lives_in", m[1], "places", m[0]) }
        if let m = match(#"\bmy (\w+) is ([A-Z][a-z]+(?: [A-Z][a-z]+)?)"#) {
            let people = ["manager", "boss", "sister", "brother", "partner", "wife", "husband", "mom", "dad", "friend"]
            add(m[1].lowercased(), m[2], people.contains(m[1].lowercased()) ? "people" : "identity", m[0])
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["facts": facts], options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"facts":[]}"#
    }

    /// An MCP tool name advertised in the prompt, if any. Prefers a no-argument
    /// `ping`-style tool so the scripted call (which passes `{}`) succeeds.
    private static func firstMCPToolName(in prompt: String) -> String? {
        if let r = prompt.range(of: "mcp__[a-z0-9_]+__ping", options: .regularExpression) {
            return String(prompt[r])
        }
        if let r = prompt.range(of: "mcp__[a-z0-9_]+__[a-z0-9_]+", options: .regularExpression) {
            return String(prompt[r])
        }
        return nil
    }

    /// Extracts the content of the last `<start_of_turn>{role}...<end_of_turn>` block.
    private func extractLastTurn(role: String, from prompt: String) -> String? {
        let marker = "<start_of_turn>\(role)\n"
        guard let start = prompt.range(of: marker, options: .backwards) else { return nil }
        let rest = prompt[start.upperBound...]
        guard let end = rest.range(of: "<end_of_turn>") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }
}
#endif
