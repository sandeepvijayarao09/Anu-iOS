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
    private let maxTokens: Int

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
    }

    /// The channel Gemma 4 reasons in (the Android thinking probe, ADR-077).
    static let thoughtChannel = "thought"

    #if targetEnvironment(simulator)
    private static let backendName = "CPU"
    #else
    private static let backendName = "GPU"
    #endif

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
        usage = nil
        try await load()
        guard let engine else { throw ModelError.modelLoadFailed("LiteRT-LM engine unavailable") }

        let turns = GemmaPromptParser.parse(prompt)
        guard let lastUserIndex = turns.lastIndex(where: { $0.role == .user }) else {
            return AsyncStream { $0.finish() }   // nothing to answer
        }
        let latest = turns[lastUserIndex].content
        let userTurnCount = turns.filter { $0.role == .user }.count
        let key = ConversationKey(temperature: config.temperature, topP: config.topP,
                                  topK: config.topK, thinking: config.thinking)

        // Reuse the live Conversation only when this prompt continues the one we
        // were building (exactly one new user turn, unchanged sampling/thinking).
        let continues = conversation != nil
            && committedKey == key
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
            var convoConfig = ConversationConfig(initialMessages: Array(history), samplerConfig: sampler)
            if config.thinking {
                convoConfig.extraContext = ["enable_thinking": true]
                convoConfig.filterChannelContentFromKvCache = true
            }
            let convo = try await engine.createConversation(with: convoConfig)
            conversation = convo
            committedKey = key
            sentUserTurns = userTurnCount - 1
            active = convo
        }

        let stopSequences = config.stopSequences
        let message = latest
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
                    for try await chunk in active.sendMessageStream(Message(message), extraContext: extraContext) {
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
                // A cancelled/failed turn leaves the Conversation in an unknown
                // state — drop it so the next turn rebuilds with full history.
                if cancelled {
                    conversation = nil
                    committedKey = nil
                    sentUserTurns = 0
                } else {
                    sentUserTurns += 1
                    let finished = Date()
                    let written = await engine.tokenCount(of: thought + answer)
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

    func lastUsage() async -> GenerationUsage? { usage }

    func countTokens(_ text: String) async -> Int? {
        guard let engine else { return nil }
        return await engine.tokenCount(of: text)
    }

    func resetSession() async {
        conversation = nil
        committedKey = nil
        sentUserTurns = 0
    }

    private static func ms(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }
}
#endif
