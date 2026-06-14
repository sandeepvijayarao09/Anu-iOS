import Foundation

// MARK: - Hierarchical plan pipeline
//
// Planner → (specialist sub-agents) → synthesis → critic. Layered on top of the
// existing orchestrator: it reuses the shared model, tool registry, tool-call
// timeout (`executeTool`), streaming helpers, reasoning trace, and persistence.
// Engaged only when `PlanGate.shouldPlan` says a request is clearly multi-step;
// otherwise `run()` uses the unchanged single-shot `reactLoop`.

extension AgentOrchestrator {

    /// Persona for the synthesis/revision passes. `[[SYNTH]]` is a no-op tag the
    /// real model ignores; `ScriptedModel` uses it in DEBUG to return prose
    /// instead of a tool call.
    static let synthesizerPrompt = """
    You are the Synthesizer. [[SYNTH]]
    Combine the step results into a single, complete, polished answer to the \
    user's request. Do not mention the steps, the tools, or that you combined \
    anything — just give the final answer.
    """

    /// Top-level pipeline. Mutates published state directly; streams only the
    /// final (post-critic) answer to the chat.
    func planPipeline(goal: String, memoryContext: String?) async {
        // 1) PLAN
        status = .planning
        let plan = await Planner(model: model).makePlan(goal: goal, memoryContext: memoryContext)
        guard !Task.isCancelled else { return }
        reasoningSteps.append(ReasoningStep(
            iteration: 0,
            thought: "Plan: \(plan.steps.count) step\(plan.steps.count == 1 ? "" : "s")",
            action: plan.traceSummary,
            kind: .plan
        ))

        // 2) EXECUTE each step through its specialist sub-agent, sharing a
        // scratchpad. One global iteration budget bounds total sub-agent work.
        var budget = maxIterations
        var scratchpad = Scratchpad()

        for step in plan.steps {
            guard !Task.isCancelled else { return }
            let label = "Step \(step.id) · \(step.specialist.rawValue)"
            if budget <= 0 {
                reasoningSteps.append(ReasoningStep(
                    iteration: step.id,
                    thought: "[\(label)] Skipped — reasoning budget exhausted.",
                    action: "Skipped",
                    kind: .specialistStep,
                    specialist: step.specialist.rawValue
                ))
                continue
            }
            status = .thinking
            let pad = scratchpad.rendered()
            let userContent = pad.isEmpty
                ? "Your task: \(step.description)"
                : "\(pad)\n\nYour task: \(step.description)"
            let result = await runReActHeadless(
                transcript: [.user(userContent)],
                systemPromptOverride: step.specialist.systemPrompt,
                tools: toolsFor(step.specialist),
                stepOrdinal: step.id,
                stepLabel: label,
                specialist: step.specialist.rawValue,
                memoryContext: memoryContext,
                config: .agentFromSettings,
                budget: &budget
            )
            scratchpad.record(step: step.id, specialist: step.specialist, result: result)
        }
        guard !Task.isCancelled else { return }

        // 3) SYNTHESIZE a draft answer (single-step plans reuse the lone result).
        let draft: String
        if plan.isSingleStep, let only = scratchpad.entries.last {
            draft = only.result
        } else {
            status = .thinking
            draft = await synthesize(goal: goal, scratchpad: scratchpad, memoryContext: memoryContext)
        }
        guard !Task.isCancelled else { return }

        // 4) REFLECT — critic reviews the draft; at most one revision.
        status = .verifying
        let verdict = await Critic(model: model).review(goal: goal, draft: draft, scratchpad: scratchpad)
        guard !Task.isCancelled else { return }

        var finalText = draft
        switch verdict {
        case .approved:
            reasoningSteps.append(ReasoningStep(
                iteration: plan.steps.count + 1, thought: "Critic verdict", action: "Approved",
                kind: .critic))
        case .revise(let instruction):
            reasoningSteps.append(ReasoningStep(
                iteration: plan.steps.count + 1, thought: "Critic verdict",
                action: "Revise: \(instruction)", kind: .critic))
            status = .thinking
            finalText = await revise(goal: goal, draft: draft, instruction: instruction,
                                     scratchpad: scratchpad, memoryContext: memoryContext)
            guard !Task.isCancelled else { return }
        }

        // 5) PRESENT the final answer (live-typed for parity with other paths).
        await streamToUI(finalText)
        guard !Task.isCancelled else { return } // run() finalizes + appends "Stopped."
        finalizeStreamingMessage()
        conversationHistory.append(.assistant(finalText.trimmingCharacters(in: .whitespacesAndNewlines)))
        status = .idle
    }

    // MARK: - Sub-agent (bounded, headless ReAct loop)

    /// Runs one plan step as a bounded ReAct loop against a PRIVATE transcript —
    /// no chat bubbles, no `conversationHistory` mutation — and returns the
    /// step's result string. Reuses the orchestrator's `executeTool` (and thus
    /// its 30s per-tool timeout). Decrements the shared `budget`.
    func runReActHeadless(
        transcript: [AgentMessage],
        systemPromptOverride: String,
        tools: [any Tool],
        stepOrdinal: Int,
        stepLabel: String,
        specialist: String,
        memoryContext: String?,
        config: GenerationConfig,
        budget: inout Int
    ) async -> String {
        var localHistory = transcript
        var lastObservation = ""

        while budget > 0 {
            budget -= 1
            guard !Task.isCancelled else { return lastObservation }

            status = .thinking
            let window = ConversationWindow.windowed(localHistory)
            let prompt = GemmaChatTemplate.format(
                messages: window,
                tools: tools,
                memoryContext: memoryContext,
                systemPromptOverride: systemPromptOverride
            )

            var raw = ""
            do {
                let stream = try await model.generate(prompt: prompt, config: config)
                for await token in stream {
                    if Task.isCancelled { break }
                    raw += token
                }
            } catch {
                return "Error: \(error.localizedDescription)"
            }
            guard !Task.isCancelled else { return lastObservation }

            let decision = ResponseParser.parse(raw)
            switch decision {
            case .answerLocally(let answer):
                reasoningSteps.append(ReasoningStep(
                    iteration: stepOrdinal, thought: "[\(stepLabel)] \(raw)", action: "Final answer",
                    kind: .specialistStep, specialist: specialist))
                return answer

            case .callTool(let info):
                let result = await runHeadlessTool(info, label: stepLabel, ordinal: stepOrdinal,
                                                    specialist: specialist,
                                                    status: .callingTool(info.name))
                localHistory.append(.toolCall(info))
                localHistory.append(.toolResult(content: result, forCallId: info.id))
                lastObservation = result

            case .escalateToGemini(let task, let context):
                let escalateInfo = ToolCallInfo(
                    name: "escalate_to_gemini",
                    arguments: .object(["task": .string(task), "context": .string(context)])
                )
                let result = await runHeadlessTool(escalateInfo, label: stepLabel,
                                                    ordinal: stepOrdinal, specialist: specialist,
                                                    status: .escalating)
                localHistory.append(.toolCall(escalateInfo))
                localHistory.append(.toolResult(content: result, forCallId: escalateInfo.id))
                lastObservation = result
            }
        }

        // Budget exhausted with no final answer — return the latest observation.
        return lastObservation.isEmpty
            ? "(step incomplete — ran out of reasoning budget)"
            : lastObservation
    }

    /// Runs a tool for a sub-agent and records a trace step (NO chat bubble).
    private func runHeadlessTool(
        _ info: ToolCallInfo, label: String, ordinal: Int, specialist: String,
        status newStatus: AgentStatus
    ) async -> String {
        status = newStatus
        let action = info.name == "escalate_to_gemini" ? "Escalate to Gemini" : "Call tool: \(info.name)"
        reasoningSteps.append(ReasoningStep(
            iteration: ordinal, thought: "[\(label)] calling \(info.name)", action: action,
            kind: .tool, specialist: specialist))
        let result: String
        if let blocked = connectorBlockReason(for: info.name) {
            result = blocked
        } else {
            result = await executeTool(info)
        }
        if let i = reasoningSteps.indices.last {
            let prior = reasoningSteps[i]
            reasoningSteps[i] = ReasoningStep(
                iteration: prior.iteration,
                thought: prior.thought,
                action: prior.action,
                observation: result,
                kind: prior.kind,
                specialist: prior.specialist
            )
        }
        status = .thinking
        return result
    }

    // MARK: - Synthesis / revision / presentation helpers

    private func synthesize(goal: String, scratchpad: Scratchpad, memoryContext: String?) async -> String {
        let userTurn = """
        \(scratchpad.rendered())

        Using the results above, write the complete final answer to this request:
        \(goal)
        """
        let prompt = GemmaChatTemplate.format(
            messages: [.user(userTurn)], tools: [],
            memoryContext: memoryContext, systemPromptOverride: Self.synthesizerPrompt)
        let text = await generateText(prompt: prompt, config: .fromSettings)
        return text.isEmpty ? (scratchpad.entries.last?.result ?? goal) : text
    }

    private func revise(goal: String, draft: String, instruction: String,
                        scratchpad: Scratchpad, memoryContext: String?) async -> String {
        let userTurn = """
        Original request:
        \(goal)

        Draft answer:
        \(draft)

        Apply this fix and return the improved final answer:
        \(instruction)
        """
        let prompt = GemmaChatTemplate.format(
            messages: [.user(userTurn)], tools: [],
            memoryContext: memoryContext, systemPromptOverride: Self.synthesizerPrompt)
        let text = await generateText(prompt: prompt, config: .fromSettings)
        return text.isEmpty ? draft : text
    }

    /// Headless text generation — accumulates the full response, no UI streaming.
    private func generateText(prompt: String, config: GenerationConfig) async -> String {
        var raw = ""
        do {
            let stream = try await model.generate(prompt: prompt, config: config)
            for await token in stream {
                if Task.isCancelled { break }
                raw += token
            }
        } catch {
            return ""
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Live-types an already-computed string into a chat bubble using the shared
    /// streaming helpers (does not finalize — the caller does, after a cancel
    /// check, so cancellation mid-stream is handled by `run()`).
    private func streamToUI(_ text: String) async {
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        for (i, word) in words.enumerated() {
            if Task.isCancelled { break }
            await updateStreamingMessage(token: i == 0 ? String(word) : " \(word)", iteration: 0)
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Tool subset per specialist

    func toolsFor(_ specialist: Specialist) -> [any Tool] {
        let all = toolRegistry.allTools
        guard !specialist.seesAllTools else { return all }
        return all.filter { specialist.allowedToolNames.contains($0.name) }
    }
}
