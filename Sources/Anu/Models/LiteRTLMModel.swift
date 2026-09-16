import Foundation
import CoreGraphics

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
actor LiteRTLMModel: LocalLanguageModel {
    nonisolated let modelName: String

    private let modelPath: String
    private let maxTokens: Int

    private var engine: Engine?
    private var conversation: Conversation?
    private var sentUserTurns = 0
    private var committedSampling: (Float, Float, Int)?

    init(modelPath: String, modelName: String = "Gemma 4 E4B (LiteRT-LM)", maxTokens: Int = 4096) {
        self.modelPath = modelPath
        self.modelName = modelName
        self.maxTokens = maxTokens
    }

    func load() async throws {
        guard engine == nil else { return }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw ModelError.modelNotFound((modelPath as NSString).lastPathComponent)
        }
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
            let config = try EngineConfig(modelPath: modelPath,
                                          backend: backend,
                                          maxNumTokens: maxTokens,
                                          cacheDir: NSTemporaryDirectory())
            let engine = Engine(engineConfig: config)
            try await engine.initialize()   // Engine is an actor → cross-actor await
            self.engine = engine
        } catch {
            throw ModelError.modelLoadFailed(error.localizedDescription)
        }
    }

    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String> {
        try await generate(prompt: prompt, image: nil, config: config)
    }

    func generate(prompt: String, image: CGImage?, config: GenerationConfig) async throws -> AsyncStream<String> {
        try await load()
        guard let engine else { throw ModelError.modelLoadFailed("LiteRT-LM engine unavailable") }

        let turns = GemmaPromptParser.parse(prompt)
        guard let lastUserIndex = turns.lastIndex(where: { $0.role == .user }) else {
            return AsyncStream { $0.finish() }   // nothing to answer
        }
        let latest = turns[lastUserIndex].content
        let userTurnCount = turns.filter { $0.role == .user }.count
        let sampling = (config.temperature, config.topP, config.topK)

        // Reuse the live Conversation only when this prompt continues the one we
        // were building (exactly one new user turn, unchanged sampling).
        let continues = conversation != nil
            && (committedSampling.map { $0 == sampling } ?? false)
            && userTurnCount == sentUserTurns + 1

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
            let convo = try await engine.createConversation(
                with: ConversationConfig(initialMessages: Array(history), samplerConfig: sampler))
            conversation = convo
            committedSampling = sampling
            sentUserTurns = userTurnCount - 1
            active = convo
        }

        let stopSequences = config.stopSequences
        let message = latest
        return AsyncStream<String> { continuation in
            let producer = Task {
                var filter = StreamStopFilter(stopSequences: stopSequences)
                var cancelled = false
                do {
                    // Each chunk is a Message carrying the incremental text.
                    for try await chunk in active.sendMessageStream(Message(message)) {
                        if Task.isCancelled {
                            cancelled = true
                            try? active.cancel()
                            break
                        }
                        let out = filter.process(chunk.toString)
                        if !out.isEmpty { continuation.yield(out) }
                        if filter.finished { try? active.cancel(); break }
                    }
                } catch {
                    cancelled = true
                    continuation.yield("\n[Generation error: \(error.localizedDescription)]")
                }
                // A cancelled/failed turn leaves the Conversation in an unknown
                // state — drop it so the next turn rebuilds with full history.
                if cancelled {
                    conversation = nil
                    committedSampling = nil
                    sentUserTurns = 0
                } else {
                    sentUserTurns += 1
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    func resetSession() async {
        conversation = nil
        committedSampling = nil
        sentUserTurns = 0
    }
}
#endif
