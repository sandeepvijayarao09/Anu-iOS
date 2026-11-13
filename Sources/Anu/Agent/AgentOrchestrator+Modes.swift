import Foundation
import CoreGraphics

// Generation modes (chat / cloud / ReAct), split out of the AgentOrchestrator core.
extension AgentOrchestrator {
    // MARK: - Chat mode (single friendly turn, no tools)

    /// `images` go to the model with the newest message (at most four). A
    /// `shield` holds the stream at a possible code and masks the answer before
    /// it's shown or saved, for turns with a photo or PDF in view (ADR-082).
    func chatTurn(image: CGImage? = nil, images: [CGImage] = [], shield: AnswerShield? = nil,
                  memoryContext: String? = nil) async {
        status = .streaming
        let window = ConversationWindow.windowed(Self.modelView(conversationHistory))
        let prompt = GemmaChatTemplate.formatChat(messages: window, memoryContext: memoryContext)
        let pictures = Array((images.isEmpty ? (image.map { [$0] } ?? []) : images).prefix(PictureBudget.maxInView))

        var response = ""
        let started = Date()
        var firstToken: Date?
        do {
            let stream = try await model.generate(prompt: prompt, images: pictures, config: GenerationConfig.chat.applyingThinkingSetting().capped(guardTokenCap))
            for await token in stream {
                if Task.isCancelled { break }
                if firstToken == nil { firstToken = Date() }
                response += token
                let shown = shield?.next(token) ?? token
                if !shown.isEmpty { await updateStreamingMessage(token: shown, iteration: 1) }
            }
        } catch {
            let errMsg = AgentMessage.assistant("Error generating response: \(error.localizedDescription)")
            appendMessage(errMsg)
            status = .error(error.localizedDescription)
            return
        }
        guard !Task.isCancelled else { return }
        await recordGeneration(prompt: prompt, response: response, started: started, firstToken: firstToken)

        var answer = response.trimmingCharacters(in: .whitespacesAndNewlines)
        // The engine's own error text is never shown or kept (seen on device).
        if let friendly = Self.friendlyEngineError(answer) {
            await updateStreamingMessage(token: "", iteration: 1)
            replaceStreamingMessage(with: friendly)
            finalizeStreamingMessage()
            status = .idle
            return
        }
        if let shield {
            // Shown whole and masked; the saved chat keeps only the masked answer.
            answer = shield.finish(answer)
            await updateStreamingMessage(token: "", iteration: 1)   // a bubble, even if all was held
            replaceStreamingMessage(with: answer)
        }
        finalizeStreamingMessage()
        conversationHistory.append(.assistant(answer))
        status = .idle
    }

    // MARK: - Cloud mode (model classifier chose Gemini directly)

    func cloudTurn(userMessage: String) async {
        // Resolve the provider once (private compute preferred when configured).
        let provider = CloudProvider.resolved() ?? .gemini

        // PII never leaves the device — the destination sees the sanitized task
        // (and the tool card honestly shows what was actually sent)
        let sanitized = PIISanitizer.sanitize(userMessage)
        if sanitized.redactions > 0 {
            let target = provider.targetName
            addSystemMessage("Redacted \(sanitized.redactions) personal detail\(sanitized.redactions == 1 ? "" : "s") before sending to \(target).")
        }
        // Pass the RAW message — the escalation tool is the single funnel that
        // sanitizes and records the egress, so it sees the real redaction count.
        let info = ToolCallInfo(
            name: provider.escalationToolName,
            arguments: .object([
                "task": .string(userMessage),
                "context": .string("Routed to cloud by the model classifier"),
            ])
        )
        status = .escalating
        appendMessage(.toolCall(info))
        conversationHistory.append(.toolCall(info))

        // Through the broker like every call: the route is untainted at the
        // start of a turn, so this runs without asking, and it's audited.
        let result = await gatedToolResult(info)
        guard !Task.isCancelled else { return }

        appendMessage(.toolResult(content: result, forCallId: info.id))
        conversationHistory.append(.toolResult(content: result, forCallId: info.id))

        let answer = provider.stripResponsePrefix(result)
        appendMessage(.assistant(answer))
        conversationHistory.append(.assistant(answer))
        status = .idle
    }

    // MARK: - ReAct Loop

    func reactLoop(startingIteration: Int, memoryContext: String? = nil) async {
        var iteration = startingIteration
        // A one-time note for the next generation, after an answer claimed an
        // action that never happened or leaked tool-call markup (P6). It rides
        // only in that prompt and is never saved to the conversation.
        var repairNote: String?
        // The tools this turn offers; cut to the core set once if the engine
        // says the prompt is over its token limit (seen on device).
        var offeredTools = toolsForCurrentTurn
        var shrankForLength = false

        while iteration < maxIterations {
            iteration += 1
            status = .thinking

            // Build prompt from (windowed) conversation history
            let window = ConversationWindow.windowed(conversationHistory)
            let prompt = GemmaChatTemplate.format(
                messages: repairNote.map { window + [.user($0)] } ?? window,
                tools: offeredTools,  // AI Email / Scheduling bundles, else ToolSelector
                memoryContext: memoryContext
            )

            // Call the local model
            var rawResponse = ""
            let started = Date()
            var firstToken: Date?
            do {
                status = .streaming
                let stream = try await model.generate(prompt: prompt, config: GenerationConfig.agentFromSettings.applyingThinkingSetting().capped(guardTokenCap))
                for await token in stream {
                    if Task.isCancelled { break }
                    if firstToken == nil { firstToken = Date() }
                    rawResponse += token
                    // Stream partial content to UI for the current assistant message
                    await updateStreamingMessage(token: token, iteration: iteration)
                }
            } catch {
                let errMsg = AgentMessage.assistant("Error generating response: \(error.localizedDescription)")
                appendMessage(errMsg)
                status = .error(error.localizedDescription)
                return
            }
            guard !Task.isCancelled else { return }
            if !shrankForLength, Self.isPromptTooLong(rawResponse) {
                shrankForLength = true
                offeredTools = ToolSelector.minimal(offeredTools)
                discardStreamingMessage()
                reasoningSteps.append(ReasoningStep(
                    iteration: iteration,
                    thought: "The prompt was over the on-device model's limit",
                    action: "Tried again with fewer tools",
                    kind: .critic))
                continue
            }
            await recordGeneration(prompt: prompt, response: rawResponse, started: started, firstToken: firstToken)
            if let friendly = Self.friendlyEngineError(rawResponse) {
                replaceStreamingMessage(with: friendly)
                finalizeStreamingMessage()
                status = .idle
                return
            }

            // Parse the response BEFORE finalizing the streamed bubble:
            // tool-call JSON belongs in the reasoning trace, not the chat.
            let decision = ResponseParser.parse(rawResponse)

            // Record reasoning step
            let stepKind: ReasoningStepKind
            switch decision {
            case .answerLocally: stepKind = .final
            case .callTool, .escalateToGemini: stepKind = .tool
            }
            let step = ReasoningStep(
                iteration: iteration,
                thought: rawResponse,
                action: actionDescription(for: decision),
                observation: nil,
                kind: stepKind
            )
            reasoningSteps.append(step)

            switch decision {
            case .answerLocally(let answer):
                // Checked against what the broker actually did before it
                // stands (ADR-027): one repair, never shown, then the answer is
                // settled — markup cut, an unbacked claim marked as not done.
                if let note = answerProblemNote(answer), let run = currentRunState, !run.answerRepairUsed {
                    run.answerRepairUsed = true
                    repairNote = note
                    discardStreamingMessage()
                    reasoningSteps.append(ReasoningStep(
                        iteration: iteration,
                        thought: note == ActionClaims.markupNote
                            ? "The answer leaked tool-call markup"
                            : "The answer claimed an action that didn't happen",
                        action: "Asked the model once more",
                        kind: .critic))
                    continue
                }
                let settled = settledAnswer(answer)
                if settled != answer { replaceStreamingMessage(with: settled) }
                finalizeStreamingMessage()
                conversationHistory.append(.assistant(settled))
                status = .idle
                return

            case .callTool(let toolCallInfo):
                discardStreamingMessage() // hide the raw JSON bubble
                await performToolCall(toolCallInfo, status: .callingTool(toolCallInfo.name))

            case .escalateToGemini(let task, let context):
                discardStreamingMessage()
                let escalateInfo = ToolCallInfo(
                    name: "escalate_to_gemini",
                    arguments: .object(["task": .string(task), "context": .string(context)])
                )
                await performToolCall(escalateInfo, status: .escalating)
            }

            guard !Task.isCancelled else { return }
        }

        // Max iterations reached
        let limitMsg = AgentMessage.assistant("I've reached the maximum number of reasoning steps. Here's what I found so far.")
        appendMessage(limitMsg)
        conversationHistory.append(limitMsg)
    }

    /// Why an answer can't stand as is: it claims an action the broker never
    /// recorded, or it leaked tool-call markup. Nil when it's fine.
    func answerProblemNote(_ answer: String) -> String? {
        if ActionClaims.hasControlMarkup(answer) { return ActionClaims.markupNote }
        if ActionClaims.claimsAction(answer), !(currentRunState?.didWrite ?? false) {
            return ActionClaims.nothingDoneNote
        }
        return nil
    }

    /// An answer after its one repair: markup is cut, and a claim with no write
    /// behind it says plainly that nothing was done.
    func settledAnswer(_ answer: String) -> String {
        var text = answer
        if ActionClaims.hasControlMarkup(text) { text = ActionClaims.strippingMarkup(text) }
        if ActionClaims.claimsAction(text), !(currentRunState?.didWrite ?? false) {
            text += "\n\n" + ActionClaims.notDoneWarning
        }
        return text.isEmpty ? "Sorry — I couldn't put that into words. Could you say it another way?" : text
    }

    /// Shared tool-call execution: show the call card, run with timeout,
    /// record result in chat + history + reasoning trace.
    func performToolCall(_ info: ToolCallInfo, status newStatus: AgentStatus) async {
        status = newStatus
        appendMessage(.toolCall(info))
        conversationHistory.append(.toolCall(info))

        let result = await gatedToolResult(info)

        appendMessage(.toolResult(content: result, forCallId: info.id))
        conversationHistory.append(.toolResult(content: result, forCallId: info.id))

        if let idx = reasoningSteps.indices.last {
            let prior = reasoningSteps[idx]
            reasoningSteps[idx] = ReasoningStep(
                iteration: prior.iteration,
                thought: prior.thought,
                action: prior.action,
                observation: result,
                kind: prior.kind,
                specialist: prior.specialist
            )
        }
    }

}

extension AgentOrchestrator {
    /// A plain sentence for an engine failure that reached the answer text
    /// ("[Generation error: …]" from LiteRT-LM), or nil for a real answer.
    static func friendlyEngineError(_ response: String) -> String? {
        guard response.contains("[Generation error:") else { return nil }
        if isPromptTooLong(response) {
            return "That was too long for the on-device model to take in at once. Start a new chat, or send a shorter message."
        }
        if response.contains("Vision executor") {
            return "Anu couldn't look at that picture on this phone just now. Please try again."
        }
        return "The on-device model ran into a problem and couldn't answer. Please try again."
    }

    /// LiteRT-LM's answer when a prompt exceeds the engine's token limit.
    static func isPromptTooLong(_ response: String) -> Bool {
        response.contains("Input token ids are too long") || response.contains("Exceeding the maximum number of tokens")
    }
}
