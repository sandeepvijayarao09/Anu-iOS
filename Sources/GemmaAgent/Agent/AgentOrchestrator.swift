import Foundation
import Combine
import CoreGraphics
import ImageIO

// MARK: - Orchestrator

@MainActor
final class AgentOrchestrator: ObservableObject {
    /// Single shared instance — the UI and App Intents (Siri/Shortcuts)
    /// must drive the same conversation.
    static let shared = AgentOrchestrator()

    // Published state for UI
    @Published var messages: [AgentMessage] = []
    @Published var status: AgentStatus = .idle
    @Published var reasoningSteps: [ReasoningStep] = []
    @Published var isThinking: Bool = false
    private var didSetup = false

    // Internal — `internal` (not `private`) so the PlanPipeline extension in
    // its own file can reuse the shared model, registry, budget, and history.
    // `var` so the active brain can be swapped at runtime (Settings → Model);
    // Planner/Critic read it at call time, so they pick up the new backend.
    private(set) var model: any LocalLanguageModel
    let toolRegistry: ToolRegistry
    let maxIterations = 10

    // Conversation history for context (excludes system messages in display)
    var conversationHistory: [AgentMessage] = []

    init(model: (any LocalLanguageModel)? = nil) {
        let resolvedModel = model ?? ModelFactory.makeModel()
        self.model = resolvedModel
        self.toolRegistry = ToolRegistry()

        // Register built-in tools
        self.toolRegistry.register(CalculatorTool())
        self.toolRegistry.register(WebSearchTool())
        // Device-native tools available to specialist sub-agents
        self.toolRegistry.register(DateTimeTool())
        self.toolRegistry.register(UnitConverterTool())
        self.toolRegistry.register(RemindersTool())
        self.toolRegistry.register(CalendarTool())
        self.toolRegistry.register(ContactsTool())
        // EscalateToGeminiTool is registered after init since it needs the registry
    }

    private let store = ConversationStore()

    func setup() async {
        // Idempotent — called from both the UI and App Intents
        guard !didSetup else { return }
        didSetup = true

        // Test isolation / fresh-start support: launch with
        // "-reset_conversation YES" to wipe persisted state
        if UserDefaults.standard.bool(forKey: "reset_conversation") {
            store.clear()
            _ = InboxStore().drain()   // discard any stale queued requests (test isolation)
        } else if let saved = store.load(), messages.isEmpty {
            // Restore the previous conversation (chats survive restarts)
            messages = saved.messages
            conversationHistory = saved.history
        }

        // Register escalation tool with self as callback
        let escalateTool = EscalateToGeminiTool(
            geminiClient: GeminiClient()
        )
        toolRegistry.register(escalateTool)

        // Connect external connectors (MCP servers, REST, app launchers) in the
        // background so a slow/dead MCP server can't delay model loading. Tools
        // appear in the registry as soon as discovery finishes.
        Task { await self.reloadConnectors() }

        do {
            status = .thinking
            addSystemMessage("Loading \(model.modelName)… this can take a minute. You can type — your message will be answered once the model is ready.")
            try await model.load()
            status = .idle
            addSystemMessage("Model loaded: \(model.modelName)")
        } catch {
            status = .error(error.localizedDescription)
            addSystemMessage("Failed to load model: \(error.localizedDescription)")
        }

        // Run anything queued before launch (a Share Sheet hand-off or a widget
        // workflow tapped from cold start) now that setup is complete — the
        // scenePhase drain may have fired before `didSetup` was true.
        await drainInbox()
    }

    // MARK: - Main Entry Point

    private var currentRun: Task<Void, Never>?

    func run(userMessage: String) async {
        await run(userMessage: userMessage, imageData: nil)
    }

    func run(userMessage: String, imageData: Data?) async {
        // Already busy — don't silently drop (e.g. a Siri/Shortcuts invocation
        // fired mid-generation). Surface it so the user isn't left wondering.
        guard !isThinking else {
            addSystemMessage("Still working on the previous message — tap Stop first, or wait for it to finish.")
            return
        }

        let userMsg = AgentMessage.user(userMessage, imageData: imageData)
        appendMessage(userMsg)
        conversationHistory.append(userMsg)

        isThinking = true
        reasoningSteps = []
        // Open a new privacy-ledger turn so any egress this turn is attributed
        // to it and the "what left your device" chip can summarize it.
        PrivacyLedger.shared.beginTurn()

        // Explicit memory capture: "remember <fact>" saves a visible,
        // editable note (Settings → Memory) without a model round-trip
        if let fact = Self.rememberedFact(in: userMessage) {
            MemoryStore.shared.add(fact)
            let confirmation = AgentMessage.assistant(
                "Got it — I'll remember that. You can see and edit everything I remember in Settings → Memory."
            )
            appendMessage(confirmation)
            conversationHistory.append(confirmation)
            isThinking = false
            store.save(messages: messages, history: conversationHistory)
            return
        }

        defer {
            isThinking = false
            currentRun = nil
            if case .planning = status { status = .idle }
            if case .thinking = status { status = .idle }
            if case .callingTool(_) = status { status = .idle }
            if case .escalating = status { status = .idle }
            if case .streaming = status { status = .idle }
            if case .verifying = status { status = .idle }
        }

        // Two on-device ML decisions before any generation:
        // 1) Task classifier — what kind of request is this?
        // 2) Model classifier — which model/path deserves it?
        // Image turns go to the local vision model directly (only the
        // on-device chat path is vision-capable).
        let classification = TaskClassifier.shared.classify(userMessage)
        let image = imageData.flatMap(Self.cgImage(from:))

        // Personalization layer (NotebookLM-style): EVERY prompt carries a
        // standing profile of recent memories plus query-relevant older
        // notes, injected as numbered ground-truth sources
        let (usedMemories, memoryContext) = MemoryStore.shared.context(for: userMessage)
        if !usedMemories.isEmpty {
            let cited = usedMemories.enumerated()
                .map { "[M\($0.offset + 1)] \($0.element.content.prefix(60))" }
                .joined(separator: "; ")
            reasoningSteps.append(ReasoningStep(
                iteration: 0,
                thought: "Personalization layer (\(usedMemories.count) memories): \(cited)",
                action: "Memory grounding",
                kind: .memory
            ))
        }
        let route: ModelRoute = image != nil
            ? .onDeviceChat
            : ModelClassifier.route(task: classification, cloudAvailable: ModelClassifier.cloudAvailable)
        reasoningSteps.append(ReasoningStep(
            iteration: 0,
            thought: String(format: "Task: %@ (confidence %.2f)%@",
                            classification.type.rawValue, classification.confidence,
                            image != nil ? " + image" : ""),
            action: "Route → \(route.displayName)",
            kind: .route
        ))

        // The work runs in a child task so cancel() can stop it mid-stream.
        let task = Task {
            switch route {
            case .onDeviceChat:
                await chatTurn(image: image, memoryContext: memoryContext)
            case .onDeviceAgent:
                // Clearly multi-step requests get the full Planner→Executor→
                // Critic pipeline; everything else stays on the fast single-shot
                // loop (unchanged behavior).
                if PlanGate.shouldPlan(task: classification, message: userMessage) {
                    await planPipeline(goal: userMessage, memoryContext: memoryContext)
                } else {
                    await reactLoop(startingIteration: 0, memoryContext: memoryContext)
                }
            case .cloudEscalate:
                await cloudTurn(userMessage: userMessage)
            }
        }
        currentRun = task
        await task.value

        if task.isCancelled {
            finalizeStreamingMessage()
            messages.append(.system("Stopped."))
            status = .idle
        }

        // Persist after every completed turn
        store.save(messages: messages, history: conversationHistory)
    }

    /// Stops the in-flight generation (Stop button).
    func cancel() {
        currentRun?.cancel()
    }

    /// Runs any prompts queued in the App Group inbox — by the Share Sheet, a
    /// home-screen widget button, or a Siri/Shortcuts workflow. Called when the
    /// app becomes active and on the in-process inbox nudge. Skips while busy;
    /// the items stay queued for the next drain.
    func drainInbox() async {
        guard didSetup, !isThinking else { return }
        let requests = InboxStore().drain()
        for request in requests {
            await run(userMessage: request.prompt)
        }
    }

    /// Rebuilds the active brain from the current `selected_model` choice and
    /// loads it in place — no relaunch. Guarded so it can't swap mid-reply.
    /// Does not touch connectors, memory, or conversation state.
    func switchActiveModel() async {
        guard !isThinking else {
            addSystemMessage("Finish or stop the current reply before switching models.")
            return
        }
        model = ModelFactory.makeModel()
        status = .thinking
        addSystemMessage("Loading \(model.modelName)…")
        do {
            try await model.load()
            status = .idle
            addSystemMessage("Switched to \(model.modelName).")
        } catch {
            status = .error(error.localizedDescription)
            addSystemMessage("Couldn't load \(model.modelName): \(error.localizedDescription)")
        }
    }

    /// Re-discovers connector tools and swaps them into the registry. Called at
    /// setup and whenever the user changes connectors in Settings.
    func reloadConnectors() async {
        await ConnectorManager.shared.refresh()
        toolRegistry.replaceConnectorTools(ConnectorManager.shared.allConnectorTools)
    }

    /// Interactive OAuth sign-in for one MCP server, then re-sync the registry so
    /// its tools appear. The browser sheet appears only here (user-initiated).
    func signInConnector(serverID: UUID) async {
        await ConnectorManager.shared.signIn(serverID: serverID)
        await reloadConnectors()
    }

    /// Forget an MCP server's OAuth token and drop its tools.
    func signOutConnector(serverID: UUID) async {
        ConnectorManager.shared.signOut(serverID: serverID)
        await reloadConnectors()
    }

    /// If a tool reaches outside the device and its capability is turned off,
    /// returns a user-facing reason; otherwise nil. Keeps the agent autonomous
    /// while honoring the user's connector toggles (the block is shown in the
    /// tool card + trace, not silently dropped).
    func connectorBlockReason(for toolName: String) -> String? {
        guard let tool = toolRegistry.tool(named: toolName),
              case .external(let capability) = tool.sideEffect,
              !ConnectorManager.shared.isEnabled(capability) else { return nil }
        switch capability {
        case .appLaunch:
            return "Blocked: opening apps & running Shortcuts is turned off. Enable it in Settings → Connectors."
        case .connector:
            return "Blocked: this connector is currently disabled."
        }
    }

    // MARK: - Chat mode (single friendly turn, no tools)

    private func chatTurn(image: CGImage? = nil, memoryContext: String? = nil) async {
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

    private func cloudTurn(userMessage: String) async {
        // PII never leaves the device — the cloud sees the sanitized task
        // (and the tool card honestly shows what was actually sent)
        let sanitized = PIISanitizer.sanitize(userMessage)
        if sanitized.redactions > 0 {
            addSystemMessage("Redacted \(sanitized.redactions) personal detail\(sanitized.redactions == 1 ? "" : "s") before sending to the cloud.")
        }
        // Pass the RAW message — `EscalateToGeminiTool` is the single funnel that
        // sanitizes and records the egress, so it sees the real redaction count.
        // The local tool-call card echoes the user's own text (never leaves the
        // device); the privacy ledger shows the sanitized payload that actually
        // went out.
        let info = ToolCallInfo(
            name: "escalate_to_gemini",
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

        let answer = result
            .replacingOccurrences(of: "[Gemini Response]\n\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        appendMessage(.assistant(answer))
        conversationHistory.append(.assistant(answer))
        status = .idle
    }

    // MARK: - ReAct Loop

    private func reactLoop(startingIteration: Int, memoryContext: String? = nil) async {
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
    private func performToolCall(_ info: ToolCallInfo, status newStatus: AgentStatus) async {
        status = newStatus
        appendMessage(.toolCall(info))
        conversationHistory.append(.toolCall(info))

        let result: String
        if let blocked = connectorBlockReason(for: info.name) {
            result = blocked
        } else {
            result = await executeTool(info)
        }

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

    // MARK: - Streaming UI helpers

    private var currentStreamingMessageId: UUID? = nil

    func updateStreamingMessage(token: String, iteration: Int) async {
        if let id = currentStreamingMessageId,
           let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].content += token
        } else {
            let msg = AgentMessage(
                role: .assistant,
                content: token,
                isStreaming: true
            )
            currentStreamingMessageId = msg.id
            messages.append(msg)
        }
    }

    func finalizeStreamingMessage() {
        if let id = currentStreamingMessageId,
           let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].isStreaming = false
        }
        currentStreamingMessageId = nil
    }

    /// Removes the in-flight streamed bubble entirely — used when the raw
    /// model output was a tool call (shown as a card, not as chat text).
    private func discardStreamingMessage() {
        if let id = currentStreamingMessageId,
           let idx = messages.firstIndex(where: { $0.id == id }) {
            messages.remove(at: idx)
        }
        currentStreamingMessageId = nil
    }

    // MARK: - Tool Execution

    private static let toolTimeout: Duration = .seconds(30)

    func executeTool(_ toolCall: ToolCallInfo) async -> String {
        guard let tool = toolRegistry.tool(named: toolCall.name) else {
            return "Error: Tool '\(toolCall.name)' not found"
        }

        // Race the tool against a timeout so a hung tool (network etc.)
        // can't stall the agent loop forever.
        return await withTaskGroup(of: String.self) { group in
            group.addTask {
                do {
                    return try await tool.execute(arguments: toolCall.arguments)
                } catch {
                    return "Tool error: \(error.localizedDescription)"
                }
            }
            group.addTask {
                try? await Task.sleep(for: Self.toolTimeout)
                return "Tool error: '\(toolCall.name)' timed out after 30 seconds"
            }
            let first = await group.next() ?? "Tool error: no result"
            group.cancelAll()
            return first
        }
    }

    // MARK: - Helpers

    private func appendMessage(_ message: AgentMessage) {
        messages.append(message)
    }

    private func addSystemMessage(_ content: String) {
        messages.append(AgentMessage.system(content))
    }

    private func actionDescription(for decision: RoutingDecision) -> String? {
        switch decision {
        case .answerLocally: return "Final answer"
        case .callTool(let info): return "Call tool: \(info.name)"
        case .escalateToGemini: return "Escalate to Gemini"
        }
    }

    /// Detects explicit memory requests: "remember (that) <fact>".
    static func rememberedFact(in message: String) -> String? {
        let lower = message.lowercased()
        for marker in ["remember that ", "remember: ", "remember "] {
            if lower.hasPrefix(marker) {
                let fact = String(message.dropFirst(marker.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return fact.isEmpty ? nil : fact
            }
        }
        return nil
    }

    private static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func clearConversation() {
        messages = []
        conversationHistory = []
        reasoningSteps = []
        status = .idle
        store.clear()
    }
}
