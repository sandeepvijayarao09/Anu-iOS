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
    /// Set when an outward action (write / app launch / remote tool) is waiting
    /// on the user's yes/no. The chat presents an alert; `resolvePendingConfirmation`
    /// answers it.
    @Published var pendingConfirmation: PendingToolConfirmation?
    private var didSetup = false

    // Internal — `internal` (not `private`) so the PlanPipeline extension in
    // its own file can reuse the shared model, registry, budget, and history.
    // `var` so the active brain can be swapped at runtime (Settings → Model);
    // Planner/Critic read it at call time, so they pick up the new backend.
    private(set) var model: any LocalLanguageModel
    let toolRegistry: ToolRegistry
    let maxIterations = 6

    // Conversation history for context (excludes system messages in display)
    var conversationHistory: [AgentMessage] = []

    init(model: (any LocalLanguageModel)? = nil, sessionsDirectory: URL? = nil) {
        let resolvedModel = model ?? ModelFactory.makeModel()
        self.model = resolvedModel
        self.toolRegistry = ToolRegistry()
        self.sessionStore = SessionStore(directory: sessionsDirectory)

        // Register built-in tools
        self.toolRegistry.register(CalculatorTool())
        self.toolRegistry.register(WebSearchTool())
        // Device-native tools available to specialist sub-agents
        self.toolRegistry.register(DateTimeTool())
        self.toolRegistry.register(UnitConverterTool())
        self.toolRegistry.register(RemindersTool())
        self.toolRegistry.register(CalendarTool())
        self.toolRegistry.register(ContactsTool())
        // Image generation (Apple Image Playground) — surfaces the created image
        // in the active chat via the shared orchestrator.
        self.toolRegistry.register(ImageGenerationTool(
            generator: ImageGeneratorFactory.make(),
            present: { data, caption in
                await AgentOrchestrator.shared.presentGeneratedImage(data, caption: caption)
            }
        ))
        // EscalateToGeminiTool is registered after init since it needs the registry
    }

    // MARK: - Sessions (privacy sandboxes)

    let sessionStore: SessionStore

    /// All sandboxes, most-recently-updated first. The drawer binds to this.
    /// Setter is module-internal (not `private(set)`) so the session-lifecycle
    /// extension in its own file can mutate it; views only read it.
    @Published var sessions: [ChatSession] = []
    /// The sandbox whose conversation is currently loaded into `messages`.
    @Published var activeSessionID: UUID? {
        didSet { activeSessionRef.set(activeSessionID?.uuidString ?? "default") }
    }
    /// Off-main mirror of `activeSessionID` so tool code (the escalation tool
    /// runs off the main actor) can read it without touching this `@MainActor`
    /// state. Updated automatically via the `didSet` above.
    let activeSessionRef = ActiveSessionRef()

    var activeSession: ChatSession? {
        sessions.first { $0.id == activeSessionID }
    }

    /// The active sandbox's on-disk conversation store. Bootstraps a session if
    /// none is set yet (defensive — `setup()` normally establishes one first).
    var activeStore: ConversationStore {
        sessionStore.conversationStore(for: ensureActiveSession())
    }

    func setup() async {
        // Idempotent — called from both the UI and App Intents
        guard !didSetup else { return }
        didSetup = true

        // Test isolation / fresh-start support: launch with
        // "-reset_sessions YES" (or the legacy "-reset_conversation YES") to wipe
        // all persisted sandboxes and start clean.
        if UserDefaults.standard.bool(forKey: "reset_sessions")
            || UserDefaults.standard.bool(forKey: "reset_conversation") {
            sessionStore.clearAll()
            _ = InboxStore().drain()   // discard any stale queued requests (test isolation)
        }
        // Private-compute config reset (test isolation / fresh demo).
        if UserDefaults.standard.bool(forKey: "reset_pcs") {
            for key in ["pcs_endpoint", DeviceAttestation.devTokenKey, DeviceAttestation.keyIdKey] {
                KeychainStore.shared.remove(forKey: key)
            }
            UserDefaults.standard.removeObject(forKey: DeviceAttestation.attestedFlagKey)
            UserDefaults.standard.removeObject(forKey: CloudProvider.preferenceKey)
        }

        // Load the session index (migrating a legacy single-file conversation on
        // first launch), restore the active sandbox, and drop any ephemeral
        // ("incognito") sandboxes that shouldn't survive a cold start.
        loadActiveSessionFromDisk()
        sweepEphemeralSessions()

        // Register escalation tool with self as callback
        let escalateTool = EscalateToGeminiTool(
            geminiClient: GeminiClient()
        )
        toolRegistry.register(escalateTool)

        // Private compute escalation — coexists with Gemini (preferred when
        // configured). Reads the active sandbox id off-main via activeSessionRef
        // so the per-sandbox ephemeral server context stays isolated.
        let privateEscalateTool = EscalateToPrivateCloudTool(
            client: PrivateComputeClient(),
            sessionIdProvider: { [activeSessionRef] in activeSessionRef.get() }
        )
        toolRegistry.register(privateEscalateTool)

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
            #if targetEnvironment(simulator)
            // The Simulator runs the model on CPU only (no Neural Engine), so
            // generation is far slower here than on a real device. Say so once,
            // and not during scripted UI tests.
            if !UserDefaults.standard.bool(forKey: "shown_sim_note"),
               !UserDefaults.standard.bool(forKey: "scripted_model") {
                UserDefaults.standard.set(true, forKey: "shown_sim_note")
                addSystemMessage("Heads up: the Simulator runs the model on CPU only (no Neural Engine), so replies are much slower here than on a real iPhone. For quick chats, turn on Fast mode in Settings → Performance.")
            }
            #endif
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

        ensureActiveSession()

        let userMsg = AgentMessage.user(userMessage, imageData: imageData)
        appendMessage(userMsg)
        conversationHistory.append(userMsg)
        autoNameIfNeeded(from: userMessage)

        isThinking = true
        reasoningSteps = []
        // Open a new privacy-ledger turn so any egress this turn is attributed
        // to it and the "what left your device" chip can summarize it.
        PrivacyLedger.shared.beginTurn()

        // Explicit memory capture: "remember <fact>" saves a visible,
        // editable note (Settings → Memory) without a model round-trip
        if let fact = Self.rememberedFact(in: userMessage) {
            if activeSession?.memoryScope == .isolated {
                let note = AgentMessage.assistant(
                    "Memory is off in this private sandbox, so I won't save that to your global memory."
                )
                appendMessage(note)
                conversationHistory.append(note)
            } else {
                MemoryStore.shared.add(fact)
                let confirmation = AgentMessage.assistant(
                    "Got it — I'll remember that. You can see and edit everything I remember in Settings → Memory."
                )
                appendMessage(confirmation)
                conversationHistory.append(confirmation)
            }
            isThinking = false
            persistActive()
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
        // Isolated sandboxes get NO global memory — neither read nor write.
        var usedMemories: [MemoryNote] = []
        var memoryContext: String? = nil
        if activeSession?.memoryScope != .isolated {
            (usedMemories, memoryContext) = MemoryStore.shared.context(for: userMessage)
        }
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
        // Fast mode: a one-tap escape hatch — every turn goes straight to the
        // single-shot chat path (no tools, no multi-step), the cheapest route.
        let fastMode = UserDefaults.standard.bool(forKey: "fast_mode")
        var route: ModelRoute = (image != nil || fastMode)
            ? .onDeviceChat
            : ModelClassifier.route(task: classification, cloudAvailable: ModelClassifier.cloudAvailable)
        // Clock/calendar/reminder/contact questions need a device tool to be
        // correct — the tool-less chat path would invent an answer (e.g. a wrong
        // time). Force them onto the agent path. (Fast mode deliberately opts out.)
        if route == .onDeviceChat, !fastMode, ModelClassifier.needsDeviceTool(userMessage) {
            route = .onDeviceAgent
        }
        // Smart routing (opt-in): let the small on-device model raise its hand
        // and escalate a task it judges beyond itself — a dual-LLM router atop
        // the heuristic. Only for the borderline cases the heuristic kept local,
        // and only when a cloud provider exists to escalate to, so the extra
        // on-device step stays rare.
        if route != .cloudEscalate,
           !fastMode,
           image == nil,
           UserDefaults.standard.bool(forKey: "smart_routing"),
           ModelClassifier.cloudAvailable,
           !ModelClassifier.needsDeviceTool(userMessage),
           Self.isJudgeEligible(classification) {
            let escalate = await judgeEscalation(userMessage)
            reasoningSteps.append(ReasoningStep(
                iteration: 0,
                thought: "On-device model self-assessed this task",
                action: "Escalation judge → \(escalate ? "ESCALATE" : "LOCAL")",
                kind: .route
            ))
            if escalate { route = .cloudEscalate }
        }
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
                // Single-shot ReAct is the default fast path (1–3 model calls).
                // The heavy Planner→Executor→Critic pipeline (~8–16 calls) is
                // opt-in via Settings → "Deep reasoning"; PlanGate is a second
                // gate so even then only clearly multi-step requests use it.
                let deepReasoning = UserDefaults.standard.bool(forKey: "deep_reasoning")
                if deepReasoning && PlanGate.shouldPlan(task: classification, message: userMessage) {
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

        // Persist after every completed turn, and float this sandbox to the top.
        persistActive()
        touchActiveSession()
    }

    /// Stops the in-flight generation (Stop button).
    func cancel() {
        // Unblock any action awaiting confirmation so the loop can unwind.
        resolvePendingConfirmation(false)
        currentRun?.cancel()
    }

    // MARK: - Outward-action consent

    /// Test seam: when set, replaces the interactive confirmation with a
    /// synchronous decision (no UI). Production leaves this nil.
    var confirmationOverride: (@MainActor (ToolCallInfo) -> Bool)?
    private var confirmationContinuation: CheckedContinuation<Bool, Never>?

    /// Whether `info`'s tool may run. On-device / read-only tools always may;
    /// outward actions (remote writes, app launches, remote tool calls) ask the
    /// user once — unless "Confirm before outward actions" is turned off. A
    /// denial is surfaced in the chat + trace, never silently dropped.
    func userApproves(_ info: ToolCallInfo) async -> Bool {
        guard let tool = toolRegistry.tool(named: info.name), tool.requiresConfirmation else {
            return true
        }
        if let override = confirmationOverride { return override(info) }
        // Default ON: only skip the prompt when explicitly disabled.
        let confirm = UserDefaults.standard.object(forKey: "confirm_external_actions") as? Bool ?? true
        guard confirm else { return true }

        pendingConfirmation = PendingToolConfirmation(
            toolName: info.name, summary: Self.consentSummary(for: info))
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            confirmationContinuation = cont
        }
    }

    /// Answers the pending confirmation — from the chat alert or a cancel.
    func resolvePendingConfirmation(_ allow: Bool) {
        pendingConfirmation = nil
        confirmationContinuation?.resume(returning: allow)
        confirmationContinuation = nil
    }

    private static func consentSummary(for info: ToolCallInfo) -> String {
        let json = info.arguments.prettyJSON
        guard json != "{}" else { return info.name }
        return json.count > 240 ? String(json.prefix(240)) + "…" : json
    }

    // MARK: - Headless completion (Siri / Shortcuts / Writing Tools)

    /// Runs ONE bounded generation on the active model with **no chat-bubble or
    /// conversation-history side effects** — the same discipline as the headless
    /// sub-agents. Backs the inline App Intents (Ask Anu inline, Summarize,
    /// Rewrite, Proofread) and writing tools, which run outside the chat UI under
    /// a Siri/Shortcuts time budget.
    ///
    /// Mutually exclusive with `run()` via `isThinking` so two generations can't
    /// race the same backend. Resets the model session first so a headless turn
    /// is self-contained and never inherits (or pollutes) the chat sandbox's
    /// KV cache. Returns trimmed text, or a short user-facing message on
    /// failure/timeout.
    func completeHeadless(
        system: String,
        user: String,
        maxTokens: Int = 256,
        timeout: Duration = .seconds(25)
    ) async -> String {
        // Intents can fire before the UI's setup() — make sure a model exists.
        await setup()
        guard !isThinking else {
            return "I'm finishing another reply right now — try again in a moment."
        }
        isThinking = true
        defer { isThinking = false }

        await model.resetSession()
        let prompt = GemmaChatTemplate.format(
            messages: [.user(user)],
            tools: [],
            systemPromptOverride: system
        )
        var config = GenerationConfig.deterministic
        config.maxNewTokens = maxTokens

        let result = await withTaskGroup(of: String?.self) { group in
            group.addTask { [model] in
                do {
                    var text = ""
                    let stream = try await model.generate(prompt: prompt, config: config)
                    for await token in stream { text += token }
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    return "Sorry — I couldn't complete that: \(error.localizedDescription)"
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil // timeout sentinel
            }
            let first = await group.next() ?? ""
            group.cancelAll()
            return first
        }
        // Don't leave the chat sandbox's cache primed with the headless prompt.
        await model.resetSession()
        return result ?? "That took too long to answer here — open the app and ask me directly."
    }

    /// Asks the active on-device model to self-assess whether a task exceeds it
    /// and should escalate to the larger cloud model (see `EscalationRouter`).
    /// Bounded and best-effort: any timeout/error stays LOCAL (`false`). Unlike
    /// `completeHeadless` it does NOT touch `isThinking` — `run()` already owns
    /// it, and this judge runs inline before the generation child task.
    func judgeEscalation(_ userMessage: String) async -> Bool {
        await model.resetSession()
        let prompt = GemmaChatTemplate.format(
            messages: [.user(userMessage)],
            tools: [],
            systemPromptOverride: EscalationRouter.systemPrompt()
        )
        var config = GenerationConfig.deterministic
        config.maxNewTokens = EscalationRouter.maxTokens

        let output: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { [model] in
                do {
                    var text = ""
                    let stream = try await model.generate(prompt: prompt, config: config)
                    for await token in stream {
                        if Task.isCancelled { break }
                        text += token
                    }
                    return text
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil // timeout sentinel
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        await model.resetSession()
        guard let output else { return false }
        return EscalationRouter.shouldEscalate(from: output)
    }

    /// Whether the escalation judge is worth consulting for a classification.
    /// Skips clearly-local (casual chat) and clearly-tool (math/web) tasks; asks
    /// only on the ambiguous middle — open-ended Q&A, generation, or a
    /// low-confidence guess that fell back to the agent loop.
    nonisolated static func isJudgeEligible(_ c: TaskClassification) -> Bool {
        if c.confidence < ModelClassifier.confidenceFloor { return true }
        switch c.type {
        case .generalQA, .codeGen, .longWriting: return true
        case .casualChat, .math, .webInfo: return false
        }
    }

    /// Appends a generated image as an assistant message in the active sandbox.
    /// Used by the Image Playground path (manual sheet + the `generate_image`
    /// tool) to surface a created image in the chat. Reuses `AgentMessage`'s
    /// `imageData` field that the bubble already renders.
    func presentGeneratedImage(_ data: Data, caption: String) {
        let msg = AgentMessage(role: .assistant, content: caption, imageData: data)
        appendMessage(msg)
        conversationHistory.append(.assistant(caption))
        persistActive()
    }

    /// Runs any prompts queued in the App Group inbox — by the Share Sheet, a
    /// home-screen widget button, or a Siri/Shortcuts workflow. Called when the
    /// app becomes active and on the in-process inbox nudge. Skips while busy;
    /// the items stay queued for the next drain.
    func drainInbox() async {
        guard didSetup, !isThinking else { return }
        let requests = InboxStore().drain()
        guard !requests.isEmpty else { return }
        // One-shot hand-offs (Share Sheet / widget / Siri) land in a dedicated
        // "Quick" sandbox so they never pollute — or get colored by — whatever
        // private chat the user was last in.
        await switchToQuickSession()
        for request in requests {
            await run(userMessage: request.prompt)
        }
    }

    /// Find-or-create the reserved "Quick" sandbox and make it active.
    private func switchToQuickSession() async {
        let quickName = "Quick"
        if let existing = sessions.first(where: { $0.name == quickName }) {
            await switchSession(to: existing.id)
        } else {
            createSession(name: quickName)
            await model.resetSession()
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
    func discardStreamingMessage() {
        if let id = currentStreamingMessageId,
           let idx = messages.firstIndex(where: { $0.id == id }) {
            messages.remove(at: idx)
        }
        currentStreamingMessageId = nil
    }

    // MARK: - Tool Execution

    private static let toolTimeout: Duration = .seconds(30)

    /// Runs a tool through the outward-action gates in order — capability block →
    /// user consent → execution — so the interactive loop and the planner
    /// sub-agents share one gate and can't drift apart.
    func gatedToolResult(_ info: ToolCallInfo) async -> String {
        if let blocked = connectorBlockReason(for: info.name) { return blocked }
        guard await userApproves(info) else { return "Blocked: you declined to run \(info.name)." }
        return await executeTool(info)
    }

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

    func appendMessage(_ message: AgentMessage) {
        messages.append(message)
    }

    func addSystemMessage(_ content: String) {
        messages.append(AgentMessage.system(content))
    }

    func actionDescription(for decision: RoutingDecision) -> String? {
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
        // Only the active sandbox's conversation. The privacy ledger is
        // independent and is cleared separately (Privacy screen → Clear).
        activeStore.clear()
    }
}
