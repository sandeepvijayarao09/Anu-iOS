import Foundation
import CoreGraphics

// Generation modes (chat / cloud / ReAct), split out of the AgentOrchestrator core.
extension AgentOrchestrator {
    // MARK: - Chat mode (single friendly turn, no tools)

    func chatTurn(image: CGImage? = nil, memoryContext: String? = nil) async {
        status = .streaming
        let window = ConversationWindow.windowed(conversationHistory)
        let prompt = GemmaChatTemplate.formatChat(messages: window, memoryContext: memoryContext)

        var response = ""
        do {
            let stream = try await model.generate(prompt: prompt, image: image, config: .chat)
            for await token in stream {
                response += token
                await updateStreamingMessage(token: token, iteration: 1)
            }
        } catch {
            let errMsg = AgentMessage.assistant("Error generating response: \(error.localizedDescription)")
            appendMessage(errMsg)
            status = .error(error.localizedDescription)
            return
        }
        guard !Task.isCancelled else { return }

        finalizeStreamingMessage()
        conversationHistory.append(.assistant(response.trimmingCharacters(in: .whitespacesAndNewlines)))
        status = .idle
    }

    // MARK: - Cloud mode (model classifier chose Gemini directly)

    func cloudTurn(userMessage: String) async {
        // Resolve the provider once (private compute preferred when configured).
        let provider = CloudProvider.resolved() ?? .gemini
        let usingPrivate = provider == .privateCloud

        // PII never leaves the device — the destination sees the sanitized task
        // (and the tool card honestly shows what was actually sent)
        let sanitized = PIISanitizer.sanitize(userMessage)
        if sanitized.redactions > 0 {
            let where_ = usingPrivate ? "your private server" : "the cloud"
            addSystemMessage("Redacted \(sanitized.redactions) personal detail\(sanitized.redactions == 1 ? "" : "s") before sending to \(where_).")
        }
        // Pass the RAW message — the escalation tool is the single funnel that
        // sanitizes and records the egress, so it sees the real redaction count.
        let info = ToolCallInfo(
            name: usingPrivate ? "escalate_to_private_cloud" : "escalate_to_gemini",
            arguments: .object([
                "task": .string(userMessage),
                "context": .string("Routed to cloud by the model classifier"),
            ])
        )
        status = .escalating
        appendMessage(.toolCall(info))
        conversationHistory.append(.toolCall(info))

        let result = await executeTool(info)
        guard !Task.isCancelled else { return }

        appendMessage(.toolResult(content: result, forCallId: info.id))
        conversationHistory.append(.toolResult(content: result, forCallId: info.id))

        let prefix = usingPrivate ? "[Private Compute Response]\n\n" : "[Gemini Response]\n\n"
        let answer = result
            .replacingOccurrences(of: prefix, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        appendMessage(.assistant(answer))
        conversationHistory.append(.assistant(answer))
        status = .idle
    }

    // MARK: - ReAct Loop

    func reactLoop(startingIteration: Int, memoryContext: String? = nil) async {
        var iteration = startingIteration

        while iteration < maxIterations {
            iteration += 1
            status = .thinking

            // Build prompt from (windowed) conversation history
            let window = ConversationWindow.windowed(conversationHistory)
            let prompt = GemmaChatTemplate.format(
                messages: window,
                tools: toolRegistry.allTools,
                memoryContext: memoryContext
            )

            // Call the local model
            var rawResponse = ""
            do {
                status = .streaming
                let stream = try await model.generate(prompt: prompt, config: .agentFromSettings)
                for await token in stream {
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
                // Final answer — already streamed to UI
                finalizeStreamingMessage()
                conversationHistory.append(.assistant(answer))
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
