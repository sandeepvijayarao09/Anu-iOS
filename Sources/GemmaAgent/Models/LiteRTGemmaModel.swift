import Foundation
import CoreGraphics

#if canImport(MediaPipeTasksGenAI)
// Implementation-only: keeps MediaPipe out of the app's module interface so
// the unit-test bundle doesn't need (or accidentally re-link) the static SDK —
// re-linking it aborts at launch with a duplicate calculator registration.
@_implementationOnly import MediaPipeTasksGenAI

/// Gemma 4 E4B running through Google's MediaPipe LLM Inference engine
/// (.litertlm package). Unlike the Core ML path, this engine ships with a
/// KV cache and prefill optimizations, so generation speed is usable on
/// device. The model file is the official litert-community release.
///
/// ⚠️ Deprecation: `LlmInference` / `LlmInference.Session` / `.Options` are
/// marked deprecated by MediaPipe ("Migrate to LiteRT LM"). They are stable
/// and shipping today; the successor — the **LiteRT-LM Swift package** — is
/// still early-preview on iOS, so migrating now would trade a known-good
/// runtime for an unproven one. The entire MediaPipe surface is confined to
/// this one file behind the `LocalLanguageModel` protocol, so the migration,
/// when LiteRT-LM Swift reaches GA, is a single-file swap with no changes to
/// the orchestrator, tools, UI, or tests. Tracked as deliberate tech debt.
actor LiteRTGemmaModel: LocalLanguageModel {
    nonisolated let modelName = "Gemma 4 E4B (LiteRT)"

    private var llm: LlmInference?
    private var loadTask: Task<LlmInference, Error>?

    // Conversation-level session reuse: keep the session (and its KV cache)
    // alive across turns and feed only the prompt delta each time
    private var session: LlmInference.Session?
    private var tracker = SessionContextTracker()
    private var sessionTemperature: Float = -1

    func load() async throws {
        guard llm == nil else { return }

        if loadTask == nil {
            guard let path = Bundle.main.path(forResource: "gemma4e4b", ofType: "litertlm") else {
                throw ModelError.modelNotFound("gemma4e4b.litertlm")
            }
            loadTask = Task.detached(priority: .userInitiated) {
                let options = LlmInference.Options(modelPath: path)
                options.maxTokens = 2048
                return try LlmInference(options: options)
            }
        }

        do {
            llm = try await loadTask!.value
        } catch {
            loadTask = nil // allow retry
            throw ModelError.modelLoadFailed(error.localizedDescription)
        }
    }

    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String> {
        try await generate(prompt: prompt, image: nil, config: config)
    }

    func generate(prompt: String, image: CGImage?, config: GenerationConfig) async throws -> AsyncStream<String> {
        try await load()
        guard let llm else {
            throw ModelError.modelLoadFailed("LiteRT engine unavailable")
        }

        // Reuse the live session when the prompt simply extends what it has
        // already consumed (multi-turn chat): feed only the delta and skip
        // re-prefilling the whole history. Rebuild on divergence (clear/trim),
        // when sampling needs differ (chat vs agent mode), or for image turns
        // (vision modality must be enabled at session creation).
        let activeSession: LlmInference.Session
        let feed = tracker.feed(for: prompt)
        if image == nil,
           let existing = session,
           sessionTemperature == config.temperature,
           case .append(let delta) = feed {
            try existing.addQueryChunk(inputText: delta)
            activeSession = existing
        } else {
            // Sampling lives on the Session (NOT engine Options in this SDK).
            // GenerationConfig.chat samples warm for conversation;
            // .agentFromSettings clamps temperature for tool-call JSON.
            let sessionOptions = LlmInference.Session.Options()
            sessionOptions.temperature = config.temperature
            sessionOptions.topp = config.topP
            sessionOptions.topk = config.topK
            sessionOptions.randomSeed = 101
            sessionOptions.enableVisionModality = (image != nil)

            activeSession = try LlmInference.Session(llmInference: llm, options: sessionOptions)
            try activeSession.addQueryChunk(inputText: prompt)
            if let image {
                try activeSession.addImage(image: image)
            }
            session = activeSession
            sessionTemperature = config.temperature
            tracker.reset()
        }
        tracker.didSend(fullPrompt: prompt)

        // The engine does not honor stop sequences itself — it keeps
        // generating past <end_of_turn> until maxTokens. StreamStopFilter
        // cuts the stream at the first stop marker (handling markers split
        // across chunks).
        let stopSequences = config.stopSequences + ["<turn|>"]
        return AsyncStream<String> { continuation in
            let producer = Task { [weak self] in
                var filter = StreamStopFilter(stopSequences: stopSequences)
                var rawOutput = ""
                do {
                    for try await partial in activeSession.generateResponseAsync() {
                        if Task.isCancelled { break }
                        let out = filter.process(partial)
                        if !out.isEmpty {
                            rawOutput += out
                            continuation.yield(out)
                        }
                        if filter.finished { break }
                    }
                } catch {
                    continuation.yield("\n[Generation error: \(error.localizedDescription)]")
                }
                // Stop the engine whether we hit a stop marker, were
                // cancelled (Stop button), or finished naturally
                try? activeSession.cancelGenerateResponseAsync()
                await self?.recordGeneration(rawOutput, cancelled: Task.isCancelled)
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// Update the context accounting after a generation completes. A
    /// cancelled generation leaves the session's internal state unknown,
    /// so force a rebuild next turn.
    private func recordGeneration(_ rawOutput: String, cancelled: Bool) {
        if cancelled {
            tracker.reset()
            session = nil
        } else {
            tracker.didGenerate(rawOutput)
        }
    }
}
#endif
