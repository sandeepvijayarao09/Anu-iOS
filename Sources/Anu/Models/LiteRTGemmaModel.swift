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

        // A FRESH session per turn — we deliberately do NOT reuse a session (and
        // its KV cache) across turns. Reusing one produced the field bug where
        // every turn after the first degenerated ("<end<end…", repeated
        // "Anu: user:" role labels) or threw "AddQueryChunk should not be called
        // before PredictDone". Re-prefilling the windowed prompt on a clean
        // session each turn is reliable; ConversationWindow bounds the prefill.
        //
        // Sampling lives on the Session (NOT engine Options in this SDK).
        // GenerationConfig.chat samples warm for conversation;
        // .agentFromSettings clamps temperature for tool-call JSON.
        let sessionOptions = LlmInference.Session.Options()
        sessionOptions.temperature = config.temperature
        sessionOptions.topp = config.topP
        sessionOptions.topk = config.topK
        sessionOptions.randomSeed = 101
        sessionOptions.enableVisionModality = (image != nil)

        let activeSession = try LlmInference.Session(llmInference: llm, options: sessionOptions)
        try activeSession.addQueryChunk(inputText: prompt)
        if let image {
            try activeSession.addImage(image: image)
        }

        // The engine does not honor stop sequences itself — left alone it keeps
        // emitting fake extra turns past <end_of_turn> up to maxTokens (~2048),
        // which is both slow and the source of the trailing garbage.
        // StreamStopFilter detects the first stop marker; at that point we ask
        // the engine to stop (cancelGenerateResponseAsync) AND keep consuming the
        // stream until it actually ends.
        //
        // Why keep consuming instead of `break`ing: the LlmInference engine runs
        // one generation at a time. Abandoning the loop early leaves it "busy",
        // and the next turn fails with "Response generation is already in
        // progress" / "AddQueryChunk before PredictDone". Consuming to the end
        // lets it return to idle. The cancel makes that end arrive promptly, so
        // this stays fast (≈13s/turn in the Simulator vs. ≈200s if we drained to
        // maxTokens without cancelling).
        let stopSequences = config.stopSequences
        return AsyncStream<String> { continuation in
            let producer = Task {
                var filter = StreamStopFilter(stopSequences: stopSequences)
                var emitting = true
                do {
                    for try await partial in activeSession.generateResponseAsync() {
                        if Task.isCancelled {
                            // User pressed Stop — quit emitting and ask the engine
                            // to stop, then keep consuming below so it returns to
                            // idle (see the stop-marker note).
                            emitting = false
                            try? activeSession.cancelGenerateResponseAsync()
                        }
                        guard emitting else { continue }   // drain silently to idle

                        let out = filter.process(partial)
                        if !out.isEmpty {
                            continuation.yield(out)
                        }
                        if filter.finished {
                            // The visible answer is complete. The engine doesn't
                            // honor stop sequences, so left alone it generates
                            // fake extra turns up to maxTokens (the "<end<end…" /
                            // "Anu: user:" garbage). Ask it to stop — but do NOT
                            // break: we keep consuming until generateResponseAsync
                            // ends so the single-generation engine returns to a
                            // clean idle state. Breaking here leaves it "busy" and
                            // the next turn fails with "generation already in
                            // progress" / "AddQueryChunk before PredictDone".
                            emitting = false
                            try? activeSession.cancelGenerateResponseAsync()
                        }
                    }
                } catch {
                    if emitting {
                        continuation.yield("\n[Generation error: \(error.localizedDescription)]")
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// No cross-turn session state is kept (a fresh session is built per turn),
    /// so there is nothing to reset on a sandbox switch.
    func resetSession() async {}
}
#endif
