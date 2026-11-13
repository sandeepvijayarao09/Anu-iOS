import Foundation

/// One turn's measurements, collected while it runs, for About this answer
/// (ADR-071). Each on-device generation step adds what it read and wrote; the
/// last step's first token is the answer's first word.
@MainActor
final class AnswerMeter {
    let started: Date
    let route: ModelRoute
    let memoryNotes: Int

    private(set) var steps = 0
    private(set) var tokensIn = 0
    private(set) var tokensOut = 0
    private(set) var readMs = 0
    private(set) var writeMs = 0
    private(set) var allCounted = true
    private(set) var backend: String?
    /// The last step's first token: the answer's first word.
    private(set) var lastFirstToken: Date?
    /// The last step's reasoning and how long it took.
    private(set) var thought: String?
    private(set) var thoughtMs: Int?

    init(started: Date = Date(), route: ModelRoute, memoryNotes: Int) {
        self.started = started
        self.route = route
        self.memoryNotes = memoryNotes
    }

    func add(tokensIn: Int, tokensOut: Int, readMs: Int, writeMs: Int, counted: Bool,
             backend: String?, firstToken: Date?, thought: String?, thoughtMs: Int?) {
        steps += 1
        self.tokensIn += tokensIn
        self.tokensOut += tokensOut
        self.readMs += readMs
        self.writeMs += writeMs
        allCounted = allCounted && counted
        if let backend { self.backend = backend }
        lastFirstToken = firstToken
        self.thought = thought
        self.thoughtMs = thoughtMs
    }
}

// About this answer, thinking and token calibration: what the orchestrator
// records around each generation, and attaches to the answer.
extension AgentOrchestrator {

    /// Records one finished on-device generation step: the runtime's usage when
    /// it reports one, calibrated estimates otherwise. Also feeds the token
    /// calibration (ADR-041) and puts any reasoning in the trace (ADR-077).
    func recordGeneration(prompt: String, response: String, started: Date, firstToken: Date?) async {
        let finished = Date()
        let usage = await model.lastUsage()
        let calibration = TokenCalibration.shared
        let clockRead = firstToken.map { Self.ms($0.timeIntervalSince(started)) } ?? Self.ms(finished.timeIntervalSince(started))
        let clockWrite = firstToken.map { Self.ms(finished.timeIntervalSince($0)) } ?? 0
        let tokensIn = usage?.promptTokens ?? calibration.estimate(prompt)
        let tokensOut = usage?.outputTokens ?? calibration.estimate(response + (usage?.thought ?? ""))
        answerMeter?.add(
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            readMs: usage?.firstOutputMs ?? clockRead,
            writeMs: usage?.decodeMs ?? clockWrite,
            counted: usage?.counted ?? false,
            backend: usage?.backend,
            firstToken: firstToken,
            thought: usage?.thought,
            thoughtMs: usage?.thoughtMs
        )
        if let thought = usage?.thought {
            reasoningSteps.append(ReasoningStep(
                iteration: 0,
                thought: thought,
                action: "Thought it through",
                kind: .thought
            ))
        }
        await calibration.learn(from: prompt + "\n" + response, model: model)
    }

    /// Saves this turn's details (and reasoning) on its answer, so the caption
    /// can open About this answer and restored chats keep them. Pure numbers and
    /// names: no content beyond what the chat already holds.
    func attachDetails(since userMessageID: UUID) {
        guard let meter = answerMeter,
              let start = messages.firstIndex(where: { $0.id == userMessageID }),
              let answer = messages.indices.last(where: { $0 > start && messages[$0].role == .assistant }),
              messages[answer].details == nil
        else { return }

        let turn = messages[(start + 1)..<answer]
        let tools = turn.compactMap { $0.role == .toolCall ? $0.toolCall?.name : nil }
        let offDevice = PrivacyLedger.shared.eventsForCurrentTurn.filter { $0.destination.leavesDevice }

        var tier = AnswerDetails.Tier.onDevice
        var modelName = model.modelName
        if meter.route == .cloudEscalate {
            let usedPrivate = offDevice.contains {
                if case .privateComputeServer = $0.destination { return true } else { return false }
            }
            tier = usedPrivate ? .privateCloud : .cloud
            modelName = usedPrivate ? "Private Compute" : "Gemini"
            // PCC answered when it was the last model the turn reached (a
            // failed PCC try that fell back to Gemini stays Gemini's).
            let lastModel = offDevice.last { event in
                switch event.destination {
                case .cloud, .privateComputeServer, .applePrivateCloud: return true
                default: return false
                }
            }
            if lastModel?.destination == .applePrivateCloud {
                tier = .applePrivateCloud
                modelName = AppleModelKind.privateCloud.displayName
            }
        }
        let onDevice = tier == .onDevice && meter.steps > 0
        let now = Date()
        let details = AnswerDetails(
            tier: tier,
            modelName: modelName,
            backend: onDevice ? meter.backend : nil,
            route: Self.routeLabel(meter.route, planned: reasoningSteps.contains { $0.kind == .plan }),
            escalatedFrom: nil,
            memoryNotes: meter.memoryNotes,
            toolsUsed: tools,
            destinations: tier == .onDevice ? offDevice.map(\.destination.displayName) : [],
            firstWordMs: onDevice ? meter.lastFirstToken.map { Self.ms($0.timeIntervalSince(meter.started)) } : nil,
            totalMs: Self.ms(now.timeIntervalSince(meter.started)),
            tokensIn: onDevice ? meter.tokensIn : nil,
            tokensOut: onDevice ? meter.tokensOut : nil,
            writeMs: onDevice ? meter.writeMs : nil,
            readMs: onDevice ? meter.readMs : nil,
            counted: onDevice ? meter.allCounted : nil,
            thoughtMs: meter.thoughtMs,
            completedAt: now
        )
        messages[answer].details = details
        if let thought = meter.thought { messages[answer].reasoning = thought }
        if onDevice { ModelSpeedLog.shared.record(details) }
    }

    nonisolated static func routeLabel(_ route: ModelRoute, planned: Bool) -> String {
        switch route {
        case .onDeviceChat: return "Chat"
        case .onDeviceAgent: return planned ? "Planner" : "Agent"
        case .cloudEscalate: return "Cloud"
        }
    }

    nonisolated static func ms(_ seconds: TimeInterval) -> Int { max(0, Int((seconds * 1000).rounded())) }
}

// MARK: - Side generations (Prompt lab, Test speed)

/// What a side generation produced, with its speed worked out.
struct SideGenerationResult: Sendable, Equatable {
    var text: String
    var thought: String?
    var tokensIn: Int
    var tokensOut: Int
    var counted: Bool
    var firstWordMs: Int?
    var readMs: Int
    var writeMs: Int
    var thoughtMs: Int?
    var stopped: Bool
    /// The answer reached the longest-answer limit and was cut there.
    var cut: Bool = false

    var writeRate: Double? { AnswerDetails.rate(tokensOut, writeMs) }
    var readRate: Double? { AnswerDetails.rate(tokensIn, readMs) }

    /// One line, as the prompt lab shows it.
    var speedLine: String {
        var parts: [String] = []
        if let t = thoughtMs { parts.append("thought \(AnswerDetailsText.seconds(t))") }
        if let t = firstWordMs { parts.append("first word \(AnswerDetailsText.seconds(t))") }
        if let r = readRate { parts.append("read \(AnswerDetailsText.perSecond(r, counted: counted))") }
        if let r = writeRate { parts.append("wrote \(AnswerDetailsText.perSecond(r, counted: counted))") }
        return parts.joined(separator: " · ")
    }
}

enum SideGenerationError: LocalizedError, Equatable {
    case busy
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .busy: return "Anu is answering in the chat. Try again when it's done."
        case .failed(let reason): return reason
        }
    }
}

extension AgentOrchestrator {
    /// Runs one prompt on the on-device model beside the chat: no memory, tools
    /// or history, nothing saved, never the cloud (ADR-080's side conversation).
    /// It waits for nothing: if the chat is answering, it says so. The model's
    /// session is reset before and after, so the chat's KV cache is never fed
    /// the side prompt and the side prompt never sees the chat.
    func sideGeneration(
        prompt: String,
        config: GenerationConfig,
        onToken: @MainActor (String) -> Void = { _ in }
    ) async throws -> SideGenerationResult {
        guard !isThinking else { throw SideGenerationError.busy }
        isThinking = true
        defer { isThinking = false }

        await model.resetSession()

        let started = Date()
        var firstToken: Date?
        var text = ""
        var failure: Error?
        var cut = false
        do {
            let stream = try await model.generate(prompt: prompt, config: config)
            for await token in stream {
                if Task.isCancelled { break }
                if firstToken == nil { firstToken = Date() }
                text += token
                onToken(token)
                // The longest answer, by the calibrated estimate: the runtime
                // has no per-request output limit to set.
                if TokenCalibration.shared.estimate(text) >= config.maxNewTokens { cut = true; break }
            }
        } catch {
            failure = error
        }
        let finished = Date()
        let stopped = Task.isCancelled
        let usage = stopped || cut || failure != nil ? nil : await model.lastUsage()
        await model.resetSession()
        if let failure { throw SideGenerationError.failed(failure.localizedDescription) }
        let calibration = TokenCalibration.shared
        return SideGenerationResult(
            text: text,
            thought: usage?.thought,
            tokensIn: usage?.promptTokens ?? calibration.estimate(prompt),
            tokensOut: usage?.outputTokens ?? calibration.estimate(text + (usage?.thought ?? "")),
            counted: usage?.counted ?? false,
            firstWordMs: firstToken.map { Self.ms($0.timeIntervalSince(started)) },
            readMs: usage?.firstOutputMs ?? firstToken.map { Self.ms($0.timeIntervalSince(started)) } ?? 0,
            writeMs: usage?.decodeMs ?? firstToken.map { Self.ms(finished.timeIntervalSince($0)) } ?? 0,
            thoughtMs: usage?.thoughtMs,
            stopped: stopped,
            cut: cut
        )
    }
}
