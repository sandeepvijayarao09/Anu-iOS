import Foundation

// MARK: - Native tool calling (parity A2)
//
// On Apple's tiers the model runs its own tool loop through Foundation Models'
// `Tool` protocol instead of Anu's JSON-in-text contract. The model still only
// proposes: each call it makes comes back here through `onToolCall` and runs
// through `gatedToolResult` → `ToolBroker` (risk tiers, approvals, taint,
// receipts, audit) exactly like a ReAct-loop call. These types stay free of
// FoundationModels so the orchestrator builds on every OS and the loop is unit
// tested with a fake model.

/// A model that runs its own tool loop and hands every call back to Anu.
protocol NativeToolCallingModel: LocalLanguageModel {
    /// Tokens the tool section may use. Apple's on-device context is about 4K
    /// tokens, so it gets far fewer tools than Gemma.
    var nativeToolBudgetTokens: Int { get }

    /// Streams the answer to `turn`, calling `onToolCall` for each tool the
    /// model asks for and giving it the broker's observation back.
    func respondNatively(_ turn: NativeTurn, tools: [any Tool], config: GenerationConfig,
                         onToolCall: @escaping @Sendable (ToolCallInfo) async -> String) async throws -> AsyncStream<String>
}

/// One turn for a model with its own chat format: instructions, the earlier
/// conversation as alternating entries, and the newest user message.
struct NativeTurn: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        enum Role: Sendable, Equatable { case user, assistant }
        let role: Role
        let text: String
    }

    var instructions: String
    var history: [Entry]
    var prompt: String

    /// From Anu's conversation window. The newest user message is the prompt;
    /// earlier tool calls and results become plain text, and consecutive
    /// entries from one side are merged so the history alternates.
    static func build(window: [AgentMessage], instructions: String) -> NativeTurn {
        var messages = window
        var prompt = ""
        if let last = messages.lastIndex(where: { $0.role == .user }) {
            prompt = messages[last].content
            messages.removeSubrange(last...)
        }
        var history: [Entry] = []
        for message in messages {
            let entry: Entry?
            switch message.role {
            case .user: entry = Entry(role: .user, text: message.content)
            case .assistant: entry = Entry(role: .assistant, text: message.content)
            case .toolCall:
                entry = message.toolCall.map {
                    Entry(role: .assistant, text: "(Used the \($0.name) tool: \($0.arguments.canonicalJSON))")
                }
            case .toolResult: entry = Entry(role: .user, text: "Tool result:\n\(message.content)")
            case .system: entry = nil
            }
            guard let entry, !entry.text.isEmpty else { continue }
            history.append(entry)
        }
        return NativeTurn(instructions: instructions, history: merged(history), prompt: prompt)
    }

    /// From a `GemmaChatTemplate` prompt (chat, headless and planner calls).
    /// Anu folds its system text into the first user turn, so it stays there.
    static func fromGemmaPrompt(_ prompt: String) -> NativeTurn {
        var turns = GemmaPromptParser.parse(prompt)
        var latest = ""
        if let last = turns.lastIndex(where: { $0.role == .user }) {
            latest = turns[last].content
            turns.removeSubrange(last...)
        }
        let history = turns.map { Entry(role: $0.role == .user ? .user : .assistant, text: $0.content) }
        return NativeTurn(instructions: "", history: merged(history), prompt: latest)
    }

    private static func merged(_ entries: [Entry]) -> [Entry] {
        var out: [Entry] = []
        for entry in entries {
            if let last = out.last, last.role == entry.role {
                out[out.count - 1] = Entry(role: entry.role, text: last.text + "\n\n" + entry.text)
            } else {
                out.append(entry)
            }
        }
        return out
    }
}

/// The agent instructions for Apple's models: Anu's rules without the JSON
/// tool-call protocol, which the framework replaces.
enum AppleAgentPrompt {
    static let base = """
    You are Anu, a helpful assistant on the user's device.
    - When the user asks you to do something (a reminder, an event, a timer, a message) or needs \
    live information (the time, their calendar, a contact), call the matching tool.
    - Never say you did something unless a tool did it. If a tool says it was declined or failed, say so.
    - Relative times like "tomorrow at 5pm" can be passed to tools as they are.
    - Keep answers short and plain.
    """

    static func instructions(memoryContext: String?) -> String {
        guard let memoryContext, !memoryContext.isEmpty else { return base }
        return base + "\n\n" + memoryContext
    }
}

/// The text streamed since the last tool call. A tool call closes the bubble
/// that was streaming, so the answer starts fresh after it.
@MainActor
final class NativeSegment {
    var text = ""
}

extension AgentOrchestrator {
    /// The tools a native turn offers: the AI Email / Scheduling bundle, or
    /// `ToolSelector`'s choice for this turn's words within the model's budget.
    func toolsForNativeTurn(budget: Int) -> [any Tool] {
        let skill = currentSkill
        let tools = SkillDetector.tools(for: skill, from: toolRegistry.allTools)
        guard !SkillDetector.needsTools(skill) else { return tools }
        return ToolSelector.select(tools, turns: skillTurns(),
                                   escalation: CloudProvider.resolved()?.escalationToolName,
                                   budget: budget)
    }

    /// One agent turn on a model with native tool calling. Takes the ReAct
    /// loop's place; the answer gets the same checks against what the broker
    /// actually did.
    func nativeAgentTurn(_ native: any NativeToolCallingModel, memoryContext: String?) async {
        var tools = toolsForNativeTurn(budget: native.nativeToolBudgetTokens)
        var shrank = false
        let config = GenerationConfig.agentFromSettings.applyingThinkingSetting().capped(guardTokenCap)

        while true {
            status = .thinking
            let turn = NativeTurn.build(window: ConversationWindow.windowed(conversationHistory),
                                        instructions: AppleAgentPrompt.instructions(memoryContext: memoryContext))
            reasoningSteps.append(ReasoningStep(
                iteration: 1,
                thought: "\(native.modelName) with native tool calling",
                action: "Offered tools: " + (tools.isEmpty ? "none" : tools.map(\.name).joined(separator: ", ")),
                kind: .route))

            let segment = NativeSegment()
            let started = Date()
            var firstToken: Date?
            var raw = ""
            do {
                let stream = try await native.respondNatively(turn, tools: tools, config: config) { [weak self] info in
                    guard let self else { return "Anu stopped before this tool could run." }
                    return await self.nativeToolCall(info, segment: segment)
                }
                status = .streaming
                for await token in stream {
                    if Task.isCancelled { break }
                    if firstToken == nil { firstToken = Date() }
                    raw += token
                    segment.text += token
                    await updateStreamingMessage(token: token, iteration: 1)
                }
            } catch {
                discardStreamingMessage()
                let friendly = Self.friendlyGenerationError(error)
                appendMessage(AgentMessage.assistant(friendly))
                status = .error("Couldn't answer")
                return
            }
            guard !Task.isCancelled else { return }

            if !shrank, Self.isPromptTooLong(raw) {
                shrank = true
                tools = ToolSelector.minimal(tools)
                discardStreamingMessage()
                reasoningSteps.append(ReasoningStep(
                    iteration: 1,
                    thought: "The prompt was over \(native.modelName)'s limit",
                    action: "Tried again with fewer tools",
                    kind: .critic))
                continue
            }
            await recordGeneration(prompt: turn.instructions + "\n\n" + turn.prompt, response: raw,
                                   started: started, firstToken: firstToken)
            if let friendly = Self.friendlyEngineError(raw) {
                await updateStreamingMessage(token: "", iteration: 1)
                replaceStreamingMessage(with: friendly)
                finalizeStreamingMessage()
                status = .idle
                return
            }

            let answer = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let settled = settledAnswer(answer)
            await updateStreamingMessage(token: "", iteration: 1)   // a bubble, even for an empty answer
            if settled != segment.text { replaceStreamingMessage(with: settled) }
            finalizeStreamingMessage()
            conversationHistory.append(.assistant(settled))
            reasoningSteps.append(ReasoningStep(iteration: 1, thought: settled, action: "Final answer", kind: .final))
            status = .idle
            return
        }
    }

    /// A tool call the native model proposed: shown as a card and run through
    /// the broker like any other. Returns what the model reads back.
    func nativeToolCall(_ info: ToolCallInfo, segment: NativeSegment) async -> String {
        guard !Task.isCancelled else { return "Stopped." }
        // Text before a tool call is the model thinking aloud; the answer comes after.
        discardStreamingMessage()
        segment.text = ""
        reasoningSteps.append(ReasoningStep(
            iteration: 1,
            thought: "Native tool call: \(info.name)",
            action: "Call tool: \(info.name)",
            kind: .tool))
        let escalating = info.name.hasPrefix("escalate_to_")
        await performToolCall(info, status: escalating ? .escalating : .callingTool(info.name))
        status = .streaming
        if let last = conversationHistory.last, last.role == .toolResult { return last.content }
        return "The tool returned nothing."
    }

    // MARK: - Fallbacks (parity A1)

    /// True when the cloud route should take a turn because no on-device model
    /// can run at all: Apple's and Gemma's are both unavailable.
    var noLocalModel: Bool { model is UnavailableModel }

    /// After an Apple Private Cloud Compute escalation that couldn't run (quota,
    /// network, entitlement), carries the turn on: to the next configured cloud
    /// provider, else on the device. Returns false when the result was a real
    /// answer and the turn is done.
    func continueAfterPrivateCloudFailure(_ result: String, userMessage: String) async -> Bool {
        guard EscalateToApplePCCTool.isUnavailableResult(result) else { return false }
        if let next = CloudProvider.resolved(), next != .applePCC {
            reasoningSteps.append(ReasoningStep(
                iteration: 0, thought: "Apple Private Cloud Compute couldn't take this",
                action: "Fall back → \(next.targetName)", kind: .route))
            await cloudTurn(userMessage: userMessage)
            return true
        }
        guard !noLocalModel else { return false }
        reasoningSteps.append(ReasoningStep(
            iteration: 0, thought: "Apple Private Cloud Compute couldn't take this",
            action: "Fall back → \(model.modelName) on this device", kind: .route))
        await reactLoop(startingIteration: 0)
        return true
    }
}
