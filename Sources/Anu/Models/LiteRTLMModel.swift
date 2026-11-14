import Foundation
import CoreGraphics
import os

#if canImport(LiteRTLM)
// Compiles on BOTH the iOS Anu and macOS AnuMac targets — both link the vendored
// LiteRT-LM Swift package (the AI Edge Gallery engine). Imported
// implementation-only so LiteRT-LM types stay out of Anu's module interface,
// which lets the AnuTests bundle `@testable import Anu` without linking the
// package (same reason the old MediaPipe backend used @_implementationOnly).
@_implementationOnly import LiteRTLM

/// Gemma 4 E4B on macOS via Google's **LiteRT-LM** runtime (Metal GPU) — the
/// same engine the AI Edge Gallery Mac app statically embeds. MediaPipe has no
/// macOS slice, so this is Anu's native on-device Gemma path on the Mac.
///
/// LiteRT-LM's `Conversation` manages chat history + the KV cache itself. We
/// bridge Anu's templated-prompt contract to it with `GemmaPromptParser`:
///  • consecutive turns reuse the live Conversation and send only the newest
///    user message — native KV-cache reuse (the speed win, matching Gallery);
///  • the first turn, a sampling change, or any discontinuity rebuilds a fresh
///    Conversation seeded with the full prior history via `initialMessages`, so
///    context is never lost; that one turn just re-prefills.
/// `resetSession()` drops the Conversation on sandbox/mode switches.
///
/// Thinking (ADR-077): with `GenerationConfig.thinking` on, the conversation is
/// created with the template's `enable_thinking` context, so Gemma 4 reasons in
/// its "thought" channel apart from the answer, and with channel content
/// filtered from the KV cache so the next turn never reads the reasoning. Only
/// the answer is streamed; the reasoning comes back in `lastUsage()`.
///
/// Usage (ADR-071, ADR-041): each turn records what it read and wrote from the
/// runtime's own counters (the conversation's token count before and after, and
/// the engine tokenizer for the output), and the clock around the first piece.
actor LiteRTLMModel: LocalLanguageModel {
    nonisolated let modelName: String
    /// Every build Anu runs is Gemma 4, whose template has a thought channel.
    nonisolated let supportsThinking = true

    private let modelPath: String
    private var maxTokens: Int

    private var engine: Engine?
    private var conversation: Conversation?
    private var sentUserTurns = 0
    private var committedKey: ConversationKey?
    private var usage: GenerationUsage?

    /// What a live conversation was built with; any change rebuilds it.
    private struct ConversationKey: Equatable {
        let temperature: Float
        let topP: Float
        let topK: Int
        let thinking: Bool
        /// The chat's first turn (Anu's instructions and the oldest message
        /// kept). If it changes, the instructions or the window moved, and the
        /// live Conversation no longer matches the prompt. Compared without
        /// the per-message context, which the first message's turn carries.
        let opening: Int
    }

    /// The channel Gemma 4 reasons in (the Android thinking probe, ADR-077).
    static let thoughtChannel = "thought"

    #if targetEnvironment(simulator)
    private static let backendName = "CPU"
    #else
    private static let backendName = "GPU"
    #endif
    /// Whether the engine was loaded with Gemma's vision encoder. It's loaded
    /// only when a picture is in view (ADR-075), and kept until the next unload.
    private var visionLoaded = false
    /// Pictures the live Conversation already holds; with the new message's
    /// they never pass four (ADR-094).
    private var heldImages = 0

    /// The engine's whole working space per answer: instructions, tools,
    /// the chat kept, the message and the reply together. As large as this
    /// device can hold (Gemma 4 E2B/E4B take far more): the KV cache for it
    /// is set aside when the engine loads, so phones with less memory get
    /// less. 4,096 overflowed on device (2026-11-13).
    static let contextTokens: Int = {
        #if targetEnvironment(simulator)
        return 32_768
        #else
        let gib = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return gib >= 11 ? 32_768 : gib >= 7 ? 16_384 : 8_192
        #endif
    }()
    /// What the engine falls back to if the larger cache can't be set aside.
    static let fallbackContextTokens = 8_192

    /// The context actually loaded (lowered by the fallback), readable
    /// without waiting on the actor.
    private let loadedContext: OSAllocatedUnfairLock<Int>
    nonisolated var contextTokens: Int { loadedContext.withLock { $0 } }

    init(modelPath: String, modelName: String = "Gemma 4 E4B (LiteRT-LM)", maxTokens: Int = LiteRTLMModel.contextTokens) {
        self.modelPath = modelPath
        self.modelName = modelName
        self.maxTokens = maxTokens
        self.loadedContext = OSAllocatedUnfairLock(initialState: maxTokens)
        let id = (modelName + " " + (modelPath as NSString).lastPathComponent).lowercased()
        self.hearsAudio = id.contains("gemma") && (id.contains("e2b") || id.contains("e4b"))
    }

    /// Whether this model family takes audio input (Gemma 4 E2B / E4B).
    private let hearsAudio: Bool
    /// The engine loaded with its audio executor.
    private var audioReady = false

    func load() async throws {
        try await load(vision: false)
    }

    /// The load in progress, if any. The actor lets other calls in while a
    /// load awaits, so without this two requests (a chat turn and memory
    /// learning, say) could each start loading the 3.7 GB model at once and
    /// run the phone out of memory (an `operator new` abort in the GPU
    /// delegate, seen on device 2026-11-13).
    private var loadingTask: Task<Void, Error>?
    /// What the engine is busy with before the first word (ADR-074).
    private var currentActivity: ModelActivity = .idle

    func activity() async -> ModelActivity { currentActivity }

    /// Warm start (ADR-074): load the engine now, so the first word doesn't
    /// wait for it. Load only; it never reads the chat ahead, because that
    /// read can't be stopped once it starts.
    func warmUp() async { try? await load() }

    private func load(vision: Bool) async throws {
        // Wait out any load already running, then decide afresh.
        while let current = loadingTask { _ = try? await current.value }
        if engine != nil, !vision || visionLoaded { return }
        let task = Task { try await self.performLoad(vision: vision) }
        loadingTask = task
        defer { loadingTask = nil }
        try await task.value
    }

    private func performLoad(vision: Bool) async throws {
        if engine != nil, !vision || visionLoaded { return }
        // A GPU model's first run on this phone prepares its kernels into the
        // engine cache; later loads reuse them.
        #if targetEnvironment(simulator)
        currentActivity = .loading
        #else
        let cacheEmpty = ((try? FileManager.default.contentsOfDirectory(atPath: Self.engineCacheDirectory)) ?? []).isEmpty
        currentActivity = cacheEmpty ? .settingUpGPU : .loading
        #endif
        defer { currentActivity = .idle }
        // Loading again with vision drops the text-only engine and its chat.
        engine = nil
        conversation = nil
        committedKey = nil
        sentUserTurns = 0
        heldImages = 0
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw ModelError.modelNotFound((modelPath as NSString).lastPathComponent)
        }
        do {
            try await startEngine(vision: vision)
        } catch where maxTokens > Self.fallbackContextTokens {
            // Not enough memory for the large KV cache: load with less.
            maxTokens = Self.fallbackContextTokens
            loadedContext.withLock { $0 = Self.fallbackContextTokens }
            do { try await startEngine(vision: vision) } catch {
                throw ModelError.modelLoadFailed(error.localizedDescription)
            }
        } catch {
            throw ModelError.modelLoadFailed(error.localizedDescription)
        }
    }

    private func startEngine(vision: Bool) async throws {
        do {
            // Real devices + macOS use the Metal GPU (like Gallery). The iOS
            // Simulator's Metal can't build LiteRT-LM's GPU kernels (fails with
            // "texture binding argument index 31 > 30"), so fall back to CPU
            // there so on-device dev/testing in the Simulator still runs.
            #if targetEnvironment(simulator)
            let backend: Backend = .cpu()
            #else
            let backend: Backend = .gpu
            #endif
            // Gemma 4 E2B/E4B can hear: load the audio executor on the CPU,
            // as Google's Gallery does (voice notes, Android ADR-078). Its
            // encoder only does work when a recording arrives. If this model
            // file has no audio section, load again without it.
            // The vision encoder comes along whenever a picture is in view,
            // with or without audio (on device 2026-11-13 the audio path
            // returned early without it: "Vision executor should not be null").
            let cacheDir = Self.engineCacheDirectory
            if hearsAudio {
                do {
                    let config = try EngineConfig(modelPath: modelPath,
                                                  backend: backend,
                                                  visionBackend: vision ? backend : nil,
                                                  audioBackend: .cpu(),
                                                  maxNumTokens: maxTokens,
                                                  cacheDir: cacheDir)
                    let engine = Engine(engineConfig: config)
                    try await engine.initialize()
                    self.engine = engine
                    self.audioReady = true
                    visionLoaded = vision
                    return
                } catch {
                    audioReady = false
                }
            }
            let config = try EngineConfig(modelPath: modelPath,
                                          backend: backend,
                                          visionBackend: vision ? backend : nil,
                                          maxNumTokens: maxTokens,
                                          cacheDir: cacheDir)
            let engine = Engine(engineConfig: config)
            try await engine.initialize()   // Engine is an actor → cross-actor await
            self.engine = engine
            visionLoaded = vision
        }
    }

    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String> {
        try await generate(prompt: prompt, image: nil, config: config)
    }

    func generate(prompt: String, image: CGImage?, config: GenerationConfig) async throws -> AsyncStream<String> {
        try await generate(prompt: prompt, images: image.map { [$0] } ?? [], config: config)
    }

    func generate(prompt: String, images: [CGImage], config: GenerationConfig) async throws -> AsyncStream<String> {
        usage = nil
        let pictures = Array(images.prefix(PictureBudget.maxInView)).compactMap { PhotoPreparation.jpeg($0) }
        try await load(vision: !pictures.isEmpty)
        guard let engine else { throw ModelError.modelLoadFailed("LiteRT-LM engine unavailable") }

        let turns = GemmaPromptParser.parse(prompt)
        guard let lastUserIndex = turns.lastIndex(where: { $0.role == .user }) else {
            return AsyncStream { $0.finish() }   // nothing to answer
        }
        let latest = turns[lastUserIndex].content
        let userTurnCount = turns.filter { $0.role == .user }.count
        let key = ConversationKey(temperature: config.temperature, topP: config.topP,
                                  topK: config.topK, thinking: config.thinking,
                                  opening: GemmaChatTemplate.withoutTurnContext(turns[0].content).hashValue)

        // Reuse the live Conversation only when this prompt continues the one we
        // were building (exactly one new user turn, unchanged sampling/thinking).
        let continues = conversation != nil
            && committedKey == key
            && userTurnCount == sentUserTurns + 1
            && PictureBudget.fitsInView(held: heldImages, adding: pictures.count)

        let active: Conversation
        if continues, let convo = conversation {
            active = convo
        } else {
            let sampler = try SamplerConfig(topK: config.topK, topP: config.topP, temperature: config.temperature)
            // Seed everything before the newest user turn so a rebuild keeps
            // full context (LiteRT-LM treats initialMessages as given history,
            // not something to regenerate).
            let history = turns[..<lastUserIndex].map {
                Message($0.content, role: $0.role == .user ? .user : .model)
            }
            var convoConfig = ConversationConfig(initialMessages: Array(history), samplerConfig: sampler)
            // Rebuilding from earlier turns reads them all before the answer.
            if !history.isEmpty { currentActivity = .reading }
            if config.thinking {
                convoConfig.extraContext = ["enable_thinking": true]
                convoConfig.filterChannelContentFromKvCache = true
            }
            let convo = try await engine.createConversation(with: convoConfig)
            conversation = convo
            committedKey = key
            sentUserTurns = userTurnCount - 1
            heldImages = 0
            active = convo
        }

        // Pictures go before the message's words, as Gemma reads them.
        let message = pictures.isEmpty
            ? Message(latest)
            : Message(contents: pictures.map { Content.imageData($0) } + [.text(latest)])
        heldImages += pictures.count
        return respond(on: active, message: message, config: config, isChat: true)
    }

    /// Streams `active`'s answer to `message` and records its usage. For a
    /// chat turn (`isChat`) it also keeps the live Conversation's bookkeeping;
    /// a side job's own Conversation leaves the chat's untouched.
    private func respond(on active: Conversation, message: Message, config: GenerationConfig,
                         isChat: Bool) -> AsyncStream<String> {
        let stopSequences = config.stopSequences
        let extraContext: [String: Any]? = config.thinking ? ["enable_thinking": true] : nil
        return AsyncStream<String> { continuation in
            let producer = Task {
                var filter = StreamStopFilter(stopSequences: stopSequences)
                var cancelled = false
                var answer = ""
                var thought = ""
                let started = Date()
                var firstOutput: Date?
                var firstAnswer: Date?
                let tokensBefore = active.tokenCount()
                do {
                    // Each chunk is a Message carrying the incremental text; the
                    // reasoning arrives in its own channel, apart from the answer.
                    for try await chunk in active.sendMessageStream(message, extraContext: extraContext) {
                        currentActivity = .idle   // the read is over once output comes
                        if Task.isCancelled {
                            cancelled = true
                            try? active.cancel()
                            break
                        }
                        if let piece = chunk.channels[Self.thoughtChannel], !piece.isEmpty {
                            if firstOutput == nil { firstOutput = Date() }
                            thought += piece
                        }
                        let out = filter.process(chunk.toString)
                        if !out.isEmpty {
                            if firstOutput == nil { firstOutput = Date() }
                            if firstAnswer == nil { firstAnswer = Date() }
                            answer += out
                            continuation.yield(out)
                        }
                        if filter.finished { try? active.cancel(); break }
                    }
                } catch {
                    cancelled = true
                    continuation.yield("\n[Generation error: \(error.localizedDescription)]")
                }
                currentActivity = .idle
                // A cancelled/failed turn leaves the Conversation in an unknown
                // state — drop it so the next turn rebuilds with full history.
                if cancelled {
                    if isChat {
                        conversation = nil
                        committedKey = nil
                        sentUserTurns = 0
                        heldImages = 0
                    }
                } else {
                    if isChat { sentUserTurns += 1 }
                    let finished = Date()
                    let written = await self.engine?.tokenCount(of: thought + answer)
                    let tokensAfter = active.tokenCount()
                    var read: Int?
                    if let before = tokensBefore, let after = tokensAfter, let written {
                        read = max(0, after - before - written)
                    }
                    let thoughtText = thought.trimmingCharacters(in: .whitespacesAndNewlines)
                    usage = GenerationUsage(
                        promptTokens: read,
                        outputTokens: written,
                        counted: read != nil && written != nil,
                        backend: Self.backendName,
                        thought: thoughtText.isEmpty ? nil : thoughtText,
                        thoughtMs: thoughtText.isEmpty ? nil
                            : firstAnswer.map { Self.ms($0.timeIntervalSince(started)) },
                        firstOutputMs: firstOutput.map { Self.ms($0.timeIntervalSince(started)) },
                        decodeMs: firstOutput.map { Self.ms(finished.timeIntervalSince($0)) }
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// A side job (memory learning, a PDF piece, a judge, Prompt lab): its
    /// own Conversation beside the chat's, as Google's Gallery does, so the
    /// chat keeps its cached reading and the side prompt never sees the chat.
    func generateApart(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String> {
        usage = nil
        try await load(vision: false)
        guard let engine else { throw ModelError.modelLoadFailed("LiteRT-LM engine unavailable") }
        let turns = GemmaPromptParser.parse(prompt)
        guard let last = turns.lastIndex(where: { $0.role == .user }) else { return AsyncStream { $0.finish() } }
        let history = turns[..<last].map { Message($0.content, role: $0.role == .user ? .user : .model) }
        var convoConfig = ConversationConfig(
            initialMessages: Array(history),
            samplerConfig: try SamplerConfig(topK: config.topK, topP: config.topP, temperature: config.temperature))
        if config.thinking {
            convoConfig.extraContext = ["enable_thinking": true]
            convoConfig.filterChannelContentFromKvCache = true
        }
        let side = try await engine.createConversation(with: convoConfig)
        return respond(on: side, message: Message(turns[last].content), config: config, isChat: false)
    }

    func lastUsage() async -> GenerationUsage? { usage }

    func countTokens(_ text: String) async -> Int? {
        guard let engine else { return nil }
        return await engine.tokenCount(of: text)
    }

    func resetSession() async {
        conversation = nil
        committedKey = nil
        sentUserTurns = 0
        heldImages = 0
    }

    private static func ms(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }

    /// Where LiteRT-LM keeps its prepared GPU kernels and weight caches:
    /// Library/Caches, which survives launches, so the ~1 GB is written once
    /// per model instead of again whenever the temporary folder is cleared
    /// (an iOS disk-writes report on device, 2026-11-13).
    static var engineCacheDirectory: String {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("LiteRTLM", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
}

extension LiteRTLMModel: AudioTranscribingModel {
    func canTranscribeAudio() async -> Bool {
        guard hearsAudio else { return false }
        try? await load()
        return audioReady
    }

    /// Writes one WAV piece down in a conversation of its own, beside the
    /// chat's cached one (Android S6: both can be open, and the chat keeps
    /// what it was told). Greedy, no tools, no memory, at most ~384 tokens.
    func transcribeAudio(wav: Data, prompt: String) async throws -> String {
        try await load()
        guard let engine, audioReady else {
            throw TranscriptionError.unavailable("The loaded model can't hear audio.")
        }
        let sampler = try SamplerConfig(topK: 1, topP: 1, temperature: 0)
        let side = try await engine.createConversation(with: ConversationConfig(samplerConfig: sampler))
        var text = ""
        do {
            for try await chunk in side.sendMessageStream(Message(contents: [.audioData(wav), .text(prompt)])) {
                if Task.isCancelled { try? side.cancel(); break }
                text += chunk.toString
                // ~384 tokens of words per piece.
                if text.count > 384 * 5 { try? side.cancel(); break }
            }
        } catch {
            throw TranscriptionError.failed(error.localizedDescription)
        }
        return text
    }
}
#endif
