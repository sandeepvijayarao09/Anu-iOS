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
    /// Connection state of the active brain. Drives the "Model status" section
    /// in Settings → Model (the home screen no longer posts load disclaimers).
    @Published private(set) var modelLoadState: ModelLoadState = .loading
    @Published var reasoningSteps: [ReasoningStep] = []
    @Published var isThinking: Bool = false {
        didSet { if isThinking != oldValue { isThinking ? startWaitWatch() : stopWaitWatch() } }
    }
    /// Why the answer is waiting, once it has waited a second (ADR-074):
    /// "Getting Gemma 4 E4B ready…", "Catching up on this chat…". Nil otherwise.
    @Published var waitNote: String?
    var waitWatch: Task<Void, Never>?
    /// The approval the current run is waiting on, if any. The chat shows it
    /// as the approval sheet.
    let approvals: ApprovalCenter
    /// The only way a model-proposed tool call runs (ARCHITECTURE §4).
    let broker: ToolBroker
    /// The turn being answered. Its taint, tool-call count and receipts are
    /// shared by the ReAct loop and the planner's sub-agents.
    /// Settable within the module so tests can drive one turn's loop directly.
    var currentRunState: RunState?
    /// This turn's measurements for About this answer (ADR-071).
    var answerMeter: AnswerMeter?
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

    /// Heat and battery readings for the guard (ADR-072). Settable so tests can fake it.
    var deviceConditions: any DeviceConditionsProviding = SystemDeviceConditions()
    /// This turn's cap on on-device answer tokens while the phone is guarded.
    var guardTokenCap: Int?

    init(model: (any LocalLanguageModel)? = nil, sessionsDirectory: URL? = nil) {
        let resolvedModel = model ?? ModelFactory.makeModel()
        self.model = resolvedModel
        let registry = ToolRegistry()
        let approvals = ApprovalCenter()
        self.toolRegistry = registry
        self.approvals = approvals
        self.sessionStore = SessionStore(directory: sessionsDirectory)
        self.broker = ToolBroker(
            registry: registry,
            approvals: approvals,
            audit: sessionsDirectory == nil ? .shared : ToolAuditLog(fileURL: nil),
            capabilityBlock: { tool in AgentOrchestrator.capabilityBlockReason(for: tool) }
        )

        // Register built-in tools
        self.toolRegistry.register(CalculatorTool())
        self.toolRegistry.register(WebSearchTool())
        // Device-native tools available to specialist sub-agents
        self.toolRegistry.register(DateTimeTool())
        self.toolRegistry.register(UnitConverterTool())
        self.toolRegistry.register(RemindersTool())
        self.toolRegistry.register(CalendarTool())
        self.toolRegistry.register(ContactsTool())
        // Timers & alarms — AlarmKit where the system has it, else on-device
        // local notifications (works offline).
        #if canImport(UserNotifications)
        self.toolRegistry.register(TimerTool(scheduler: SystemAlarmScheduler(fallback: LocalNotificationScheduler())))
        #endif
        // Phone controls (Android parity #16): flashlight and screen brightness.
        #if os(iOS)
        self.toolRegistry.register(FlashlightTool(torch: SystemTorch()))
        self.toolRegistry.register(BrightnessTool(screen: SystemScreenBrightness()))
        #endif
        // On-device OCR — read text from an image file (Vision, offline).
        self.toolRegistry.register(ReadTextTool())
        // Clipboard + files (offline utilities); keep-awake is iOS-only.
        self.toolRegistry.register(ClipboardTool())
        self.toolRegistry.register(FilesTool())
        #if canImport(UIKit)
        self.toolRegistry.register(KeepAwakeTool())
        #endif
        #if canImport(PDFKit)
        self.toolRegistry.register(ReadPDFTool())
        #endif
        // Photos — read (count/recent) + save to library (PhotoKit).
        self.toolRegistry.register(PhotoLibraryTool())
        // Image generation (Apple Image Playground) — surfaces the created image
        // in the active chat via the shared orchestrator.
        self.toolRegistry.register(ImageGenerationTool(
            generator: ImageGeneratorFactory.make(),
            present: { data, caption in
                await AgentOrchestrator.shared.presentGeneratedImage(data, caption: caption)
            }
        ))
        // Gmail (Android parity #10): offered only on AI Email turns (SkillDetector).
        GmailTools.makeDefault().forEach { self.toolRegistry.register($0) }
        // Agent Skills (ADR-120): load_skill, run_js, run_intent.
        SkillTools.register(in: self.toolRegistry)
        // Anu's own notes (ADR-093): notes_add, notes_search, notes_list.
        NotesTools.register(in: self.toolRegistry)
        // The Daily Brief from chat ("brief me"): a read through the broker.
        self.toolRegistry.register(DailyBriefTool())
        // Memory tools (Android parity #3): search, remember, forget, by the chat's memory access.
        MemoryTools.makeAll(MemoryToolContext(store: { MemoryStore.shared },
                                              access: { [weak self] in MemoryAccess(session: self?.activeSession) }))
            .forEach { self.toolRegistry.register($0) }
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
        // The user's own Mac (Ollama) as the top model, ADR-113.
        toolRegistry.register(EscalateToMacTool())
        // Apple's Private Cloud Compute model, when entitled (parity A1).
        toolRegistry.register(EscalateToApplePCCTool())

        // Connect external connectors (MCP servers, REST, app launchers) in the
        // background so a slow/dead MCP server can't delay model loading. Tools
        // appear in the registry as soon as discovery finishes.
        Task { await self.reloadConnectors() }

        // Model connection status is surfaced in Settings → Model, not as chat
        // "disclaimer" messages on the home screen. The chat status bar still
        // reflects readiness (Connecting… / Ready / Error) at a glance.
        do {
            modelLoadState = .loading
            status = .loadingModel
            try await model.load()
            modelLoadState = .ready
            status = .idle
        } catch {
            modelLoadState = .failed(error.localizedDescription)
            status = .error(Self.shortReason(error.localizedDescription))
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

    /// A voice note's turn: the model reads its words; the thread shows the note.
    func run(voiceNote: VoiceNoteInfo) async {
        await run(userMessage: VoiceNotePolicy.modelText(for: voiceNote), attachments: MessageAttachments(), voiceNote: voiceNote)
    }

    /// One user turn, with any photos and PDF the composer attached
    /// (ADR-094, ADR-095), or a voice note (ADR-078). `run(userMessage:imageData:)` wraps it.
    func run(userMessage: String, attachments: MessageAttachments, voiceNote: VoiceNoteInfo? = nil) async {
        // Already busy — don't silently drop (e.g. a Siri/Shortcuts invocation
        // fired mid-generation). Surface it so the user isn't left wondering.
        guard !isThinking else {
            addSystemMessage("Still working on the previous message — tap Stop first, or wait for it to finish.")
            return
        }

        ensureActiveSession()
        let turnStarted = Date()

        // One message carries at most four pictures (ADR-094).
        let photos = Array(attachments.photos.prefix(MessageAttachments.maxPhotos))
        var userMsg = AgentMessage(role: .user, content: userMessage,
                                   photos: photos.isEmpty ? nil : photos,
                                   document: attachments.document)
        userMsg.voiceNote = voiceNote
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
        // A photo or PDF never reaches memory, so a turn with one is answered.
        if attachments.isEmpty, let fact = Self.rememberedFact(in: userMessage) {
            if activeSession?.memoryScope == .isolated {
                let note = AgentMessage.assistant(
                    "Memory is off in this private sandbox, so I won't save that to your global memory."
                )
                appendMessage(note)
                conversationHistory.append(note)
            } else {
                let kept = MemoryStore.shared.add(fact) != nil
                // Memory v2: the on-device model files it as structured facts.
                if kept { MemoryLearner.shared.turnEnded() }
                let confirmation = AgentMessage.assistant(kept
                    ? "Got it — I'll remember that. You can see and edit everything I remember in Settings → Memory."
                    : "I don't keep passwords, codes, or card, bank or ID numbers in memory, so I didn't save that."
                )
                appendMessage(confirmation)
                conversationHistory.append(confirmation)
            }
            isThinking = false
            persistActive()
            return
        }

        // Memory v2: keep the user's own words to learn from later, on device
        // (never from a private sandbox or an incognito chat), and stop any
        // learning run so this turn has the model to itself.
        if activeSession?.memoryScope != .isolated, activeSession?.ephemeral != true {
            MemoryStore.shared.captureChat(userMessage,
                                           ref: activeSessionID.map { "chat:\($0.uuidString)/\(userMsg.id.uuidString)" },
                                           place: activeSession?.name)
        }
        await MemoryLearner.shared.pause()

        defer {
            MemoryLearner.shared.turnEnded()
            isThinking = false
            currentRun = nil
            currentRunState = nil
            answerMeter = nil
            if case .planning = status { status = .idle }
            if case .thinking = status { status = .idle }
            if case .callingTool = status { status = .idle }
            if case .escalating = status { status = .idle }
            if case .streaming = status { status = .idle }
            if case .verifying = status { status = .idle }
        }
        let runState = RunState(turnKey: userMsg.id.uuidString)
        currentRunState = runState
        // A recording can hold other people's words: it taints the turn, so
        // every tool call it leads to is shown to the user first (ADR-078).
        if voiceNote != nil { runState.taint() }

        // Direct tier (ADR-076): a whole phone command runs its tool through
        // the broker with no model, ahead of the router. Anything else, or a
        // turn with a photo, carries on below.
        if attachments.isEmpty, await runDirectCommand(userMessage) {
            attachReceipts(from: runState, since: userMsg.id)
            persistActive()
            touchActiveSession()
            return
        }

        // Heat and battery guard (ADR-072): a warm phone, or a low battery not
        // charging, skips the heavy steps and keeps on-device answers short.
        let guardPlan = GuardPlan.make(DeviceGuard.evaluate(deviceConditions.current()))
        guardTokenCap = guardPlan.maxOutputTokens
        if let guarding = guardPlan.guarding {
            reasoningSteps.append(ReasoningStep(
                iteration: 0, thought: guarding.note,
                action: "Guard → no planner, no escalation judge, \(DeviceGuard.answerTokens)-token answers",
                kind: .route))
        }

        // Two on-device ML decisions before any generation:
        // 1) Task classifier — what kind of request is this?
        // 2) Model classifier — which model/path deserves it?
        // Image turns go to the local vision model directly (only the
        // on-device chat path is vision-capable).
        let classification = TaskClassifier.shared.classify(userMessage)
        let images = photos.compactMap(Self.cgImage(from:))
        // A photo or PDF in the model's view keeps the turn on the phone and
        // taints it: it can hold other people's words (MEDIA-1, P4).
        let mediaInView = hasMediaInView
        if mediaInView { runState.taint() }
        // Asking Gemini by name with a photo or PDF in view gets a plain no,
        // not a quiet answer on the phone (MEDIA-1, ADR-075).
        if mediaInView, let reply = GeminiByName.mediaReply(userMessage, history: conversationHistory) {
            let answer = AgentMessage.assistant(reply)
            appendMessage(answer)
            conversationHistory.append(answer)
            persistActive()
            touchActiveSession()
            return
        }

        // Personalization layer (NotebookLM-style): EVERY prompt carries a
        // standing profile of recent memories plus query-relevant older
        // notes, injected as numbered ground-truth sources
        // Isolated sandboxes get NO global memory — neither read nor write.
        var usedMemories: [MemoryNote] = []
        var memoryContext: String?
        if activeSession?.memoryScope != .isolated {
            let previous = conversationHistory.dropLast().last(where: { $0.role == .user })?.content
            (usedMemories, memoryContext) = MemoryStore.shared.context(for: userMessage, previous: previous)
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
        var route: ModelRoute = (mediaInView || fastMode)
            ? .onDeviceChat
            : ModelClassifier.route(
                task: classification,
                cloudAvailable: ModelClassifier.cloudAvailable,
                webSearchAvailable: ModelClassifier.webSearchAvailable)
        // Clock/calendar/reminder/contact questions need a device tool to be
        // correct — the tool-less chat path would invent an answer (e.g. a wrong
        // time). Force them onto the agent path. (Fast mode deliberately opts out.)
        // An earlier photo in view doesn't stop that: "set an alarm" after a
        // camera question went to the tool-less chat, which said it was done
        // (seen on device). The photo only keeps the chat path for the turn
        // that brings it; the media gate still refuses anything off the phone.
        if route == .onDeviceChat, !fastMode, images.isEmpty, ModelClassifier.needsDeviceTool(userMessage) {
            route = .onDeviceAgent
        }
        // A message that names a turned-on skill needs load_skill (ADR-120).
        if route == .onDeviceChat, !fastMode, !mediaInView,
           !SkillMatch.matching(userMessage, SkillLibrary.shared.enabledSkills()).isEmpty {
            route = .onDeviceAgent
        }
        // Smart routing (opt-in): let the small on-device model raise its hand
        // and escalate a task it judges beyond itself — a dual-LLM router atop
        // the heuristic. Only for the borderline cases the heuristic kept local,
        // and only when a cloud provider exists to escalate to, so the extra
        // on-device step stays rare.
        if route != .cloudEscalate,
           guardPlan.allowEscalationJudge,
           !fastMode,
           !mediaInView,
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
        // No on-device model can run (A1): a configured cloud tier answers instead.
        if route != .cloudEscalate, noLocalModel, !mediaInView, ModelClassifier.cloudAvailable {
            route = .cloudEscalate
        }
        // Voice notes never go to the cloud: while one is in the model's view
        // the turn stays on the device, whatever the classifier said.
        if route == .cloudEscalate,
           VoiceNotePolicy.keepsOnDevice(ConversationWindow.windowed(conversationHistory)) {
            route = .onDeviceAgent
        }
        // AI Email / AI Scheduling (Android parity #11): their tools and the
        // user's mail stay on the on-device agent path.
        if !fastMode, !mediaInView, SkillDetector.needsTools(SkillDetector.detect(turns: skillTurns(endingWith: userMessage))) {
            route = .onDeviceAgent
        }
        reasoningSteps.append(ReasoningStep(
            iteration: 0,
            thought: String(format: "Task: %@ (confidence %.2f)%@",
                            classification.type.rawValue, classification.confidence,
                            mediaInView ? " + photo/PDF in view (on-device only)" : ""),
            action: "Route → \(route.displayName)",
            kind: .route
        ))

        answerMeter = AnswerMeter(started: turnStarted, route: route, memoryNotes: usedMemories.count,
                                  memoryFactIDs: usedMemories.map(\.id))
        // The work runs in a child task so cancel() can stop it mid-stream.
        let task = Task {
            switch route {
            case .onDeviceChat:
                if mediaInView {
                    await readDocumentInPieces(messageID: userMsg.id, pages: attachments.documentPages, question: userMessage)
                    await chatTurn(images: images, shield: AnswerShield(asked: userMessage, known: attachments.knownCodes),
                                   memoryContext: memoryContext)
                } else {
                    await chatTurn(memoryContext: memoryContext)
                }
            case .onDeviceAgent:
                // Single-shot ReAct is the default fast path (1–3 model calls).
                // The heavy Planner→Executor→Critic pipeline (~8–16 calls) is
                // opt-in via Settings → "Deep reasoning"; PlanGate is a second
                // gate so even then only clearly multi-step requests use it.
                let deepReasoning = UserDefaults.standard.bool(forKey: "deep_reasoning")
                if deepReasoning && guardPlan.allowPlanner && PlanGate.shouldPlan(task: classification, message: userMessage) {
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
        attachReceipts(from: runState, since: userMsg.id)
        if !task.isCancelled { attachDetails(since: userMsg.id) }
        // Photos the model's view has passed are let go (MEDIA-3, ADR-091).
        releasePhotosOutOfView()

        // Persist after every completed turn, and float this sandbox to the top.
        persistActive()
        touchActiveSession()
    }

    /// Stops the in-flight generation (Stop button).
    func cancel() {
        // Withdraw any approval the run is waiting on so the loop can unwind.
        approvals.cancelAll()
        AIShareConsentCenter.shared.answer(false)
        currentRun?.cancel()
    }

    /// Puts what the broker actually did under this turn's answer, in the tools'
    /// own words, so the chat shows the truth whatever the model wrote. Pure
    /// reads aren't listed; they're in the tool cards and the trace.
    private func attachReceipts(from run: RunState, since userMessageID: UUID) {
        guard !run.receipts.isEmpty,
              let start = messages.firstIndex(where: { $0.id == userMessageID }),
              let answer = messages.indices.last(where: { $0 > start && messages[$0].role == .assistant })
        else { return }
        messages[answer].receipts = run.receipts
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
        timeout: Duration = .seconds(25),
        onToken: (@Sendable (Int) -> Void)? = nil
    ) async -> String {
        // Intents can fire before the UI's setup() — make sure a model exists.
        await setup()
        guard !isThinking else {
            return "I'm finishing another reply right now — try again in a moment."
        }
        isThinking = true
        defer { isThinking = false }

        await MemoryLearner.shared.pause()   // memory learning yields the model
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
                    var count = 0
                    for await token in stream {
                        text += token
                        count += 1
                        onToken?(count)   // long-running intents report progress
                    }
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    return "Sorry — I couldn't complete that:\(error.localizedDescription)"
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
            // `next()` returns String?? here; `?? nil` flattens it to the
            // closure's String? result (NOT redundant — do not let a linter
            // strip it).
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        await model.resetSession()
        guard let output else { return false }
        return EscalationRouter.shouldEscalate(from: output)
    }

    /// Whether the escalation judge is worth consulting for a classification.
    /// Skips only the two cases a small model reliably owns: casual chat, and
    /// arithmetic (the calculator tool answers it exactly on the agent path).
    /// Everything else is eligible — open-ended Q&A, code/long-form generation,
    /// a low-confidence guess, and now **web/factual lookups**: questions about
    /// specific people, places, products, or events (e.g. "Tv9 vs ntv") are
    /// exactly where a 4B model is least reliable, so when a cloud model is
    /// configured they deserve the on-device router's second opinion rather
    /// than a confident-but-wrong local answer.
    nonisolated static func isJudgeEligible(_ c: TaskClassification) -> Bool {
        if c.confidence < ModelClassifier.confidenceFloor { return true }
        switch c.type {
        case .generalQA, .codeGen, .longWriting, .webInfo: return true
        case .casualChat, .math: return false
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
        var requests = InboxStore().drain()
        // Shared photos and PDFs wait in the composer with the chat as it is.
        let shared = requests.compactMap(\.attachments).flatMap { $0 }
        if !shared.isEmpty { SharedAttachmentInbox.shared.receive(shared) }
        requests.removeAll { !($0.attachments ?? []).isEmpty }
        guard !requests.isEmpty else { return }
        // One-shot hand-offs (Share Sheet / widget / Siri) land in a dedicated
        // "Quick" sandbox so they never pollute — or get colored by — whatever
        // private chat the user was last in.
        await switchToQuickSession()
        for request in requests {
            if let id = request.workflowID {
                WorkflowManager.shared.markRan(id: id)
            }
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
        modelLoadState = .loading
        status = .loadingModel
        do {
            try await model.load()
            modelLoadState = .ready
            status = .idle
        } catch {
            modelLoadState = .failed(error.localizedDescription)
            status = .error(Self.shortReason(error.localizedDescription))
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
    /// returns a user-facing reason; otherwise nil. The broker checks it before
    /// anything else, so the block is shown in the tool card + trace, not
    /// silently dropped.
    static func capabilityBlockReason(for tool: any Tool) -> String? {
        guard case .external(let capability) = tool.sideEffect,
              !ConnectorManager.shared.isEnabled(capability) else { return nil }
        switch capability {
        case .appLaunch:
            return "Blocked: opening apps & running Shortcuts is turned off. Enable it in Settings → Connectors."
        case .connector:
            return "Blocked: this connector is currently disabled."
        }
    }

    // MARK: - Streaming UI helpers

    private var currentStreamingMessageId: UUID?

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

    /// Replaces the in-flight streamed bubble's text, for an answer that was
    /// settled after it streamed (markup cut, a claim marked as not done).
    func replaceStreamingMessage(with text: String) {
        if let id = currentStreamingMessageId,
           let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].content = text
        }
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

    /// Runs a model-proposed tool call through the broker — the one gate the
    /// ReAct loop, the planner's sub-agents and the cloud route share — and
    /// returns what the model reads back.
    func gatedToolResult(_ info: ToolCallInfo) async -> String {
        let run = currentRunState ?? RunState(turnKey: UUID().uuidString)
        if let refusal = mediaEgressRefusal(for: info) { return refusal }
        // Refused before the tool runs, so no ledger entry and nothing sent.
        if let refusal = VoiceNotePolicy.refusal(
            forTool: info.name, history: ConversationWindow.windowed(conversationHistory)) {
            return refusal
        }
        return await broker.handle(info, run: run).observation
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
        for marker in ["remember that ", "remember: ", "remember "] where lower.hasPrefix(marker) {
            let fact = String(message.dropFirst(marker.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return fact.isEmpty ? nil : fact
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
