import Foundation

// MARK: - Direct tier (Android parity #17, ADR-076)
//
// A step before routing, not a model tier: a message that is exactly one
// phone command runs its tool with no model. The call goes through the broker
// with the same risk tiers, approvals, receipts and audit as a model's call,
// and the turn is saved like any other, labelled "On device · no model
// needed". It starts clean (untainted), because the words are the user's own
// and no model read anything. Anything the parser isn't sure of returns false
// and goes to the router as before.
extension AgentOrchestrator {
    /// The label under a Direct-tier answer (design review D20).
    static let directLabel = "On device · no model needed"

    /// Runs `message` as a whole phone command when it is one. True when the
    /// turn was answered here; false to carry on to the router.
    func runDirectCommand(_ message: String, now: Date = Date()) async -> Bool {
        guard let command = PhoneCommands.match(message, now: now) else { return false }

        switch command {
        case .answer(let text):
            reasoningSteps.append(ReasoningStep(
                iteration: 0, thought: "A phone command iOS doesn't let apps do",
                action: "Route → Direct (no model needed)", kind: .route))
            finishDirect(with: text)
            return true

        case .tool(let name, let arguments):
            // Not registered here (a Mac has no torch; app launching tools
            // arrive with the connectors), or not a valid call: let the model
            // have it rather than fail.
            guard let tool = toolRegistry.tool(named: name),
                  (try? ToolBroker.assess(tool, arguments)) != nil else { return false }
            reasoningSteps.append(ReasoningStep(
                iteration: 0, thought: "A whole phone command: \(name)",
                action: "Route → Direct (no model needed)", kind: .route))

            let info = ToolCallInfo(name: name, arguments: arguments)
            appendMessage(.toolCall(info))
            conversationHistory.append(.toolCall(info))
            status = .callingTool(name)

            let run = currentRunState ?? RunState(turnKey: UUID().uuidString)
            let outcome = await broker.handle(info, run: run)

            appendMessage(.toolResult(content: outcome.observation, forCallId: info.id))
            conversationHistory.append(.toolResult(content: outcome.observation, forCallId: info.id))
            // A photo search shows what it found, like Gallery's media search.
            let found = name == "photos" ? PhotoSearch.takeShown() : []
            finishDirect(with: Self.directAnswer(for: outcome), photos: found)
            return true
        }
    }

    private func finishDirect(with text: String, photos: [Data] = []) {
        var answer = AgentMessage.assistant(text)
        answer.label = Self.directLabel
        if !photos.isEmpty { answer.photos = photos }
        appendMessage(answer)
        conversationHistory.append(.assistant(text))
        status = .idle
    }

    /// What the user reads: the tool's own words when it acted, else plainly
    /// why nothing happened. Never a model's paraphrase.
    nonisolated static func directAnswer(for outcome: ToolOutcome) -> String {
        switch outcome {
        case .ok(let result, _, _):
            return result
        case .rejected(let reason, _, let code):
            switch code {
            case .declined: return "Okay, I didn't do that."
            case .noAnswer: return "Nothing was done, because the approval wasn't answered in time."
            case .cancelled: return "Stopped. Nothing was done."
            case .notAllowed, .budget:
                return reason.hasPrefix("Blocked: ") ? String(reason.dropFirst("Blocked: ".count)) : reason
            }
        case .failed(let reason, _):
            let cleaned = ToolError.plain(reason)
            return "I couldn't do that: \(cleaned)"
        case .invalid(let reason):
            return "I couldn't do that: \(reason)"
        }
    }
}
