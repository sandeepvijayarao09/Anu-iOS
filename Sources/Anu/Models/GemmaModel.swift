import Foundation
import CoreGraphics

// MARK: - Protocol

/// Protocol for any local language model
protocol LocalLanguageModel: Sendable {
    var modelName: String { get }
    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String>
    /// Multimodal variant — vision-capable backends override this.
    func generate(prompt: String, image: CGImage?, config: GenerationConfig) async throws -> AsyncStream<String>
    func load() async throws
    /// Drops any cached per-conversation inference state (e.g. a KV cache).
    /// Called when switching sandboxes so one session's context can't leak into
    /// another. Stateless backends use the no-op default.
    func resetSession() async
}

extension LocalLanguageModel {
    /// Text-only backends ignore the image.
    func generate(prompt: String, image: CGImage?, config: GenerationConfig) async throws -> AsyncStream<String> {
        try await generate(prompt: prompt, config: config)
    }

    /// Stateless backends keep no per-conversation state, so there's nothing to reset.
    func resetSession() async {}
}

// MARK: - Errors

enum ModelError: LocalizedError {
    case modelNotFound(String)
    case modelLoadFailed(String)
    case generationFailed(String)
    case tokenizationFailed

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let name): return "Model '\(name)' not found in app bundle"
        case .modelLoadFailed(let reason): return "Failed to load model: \(reason)"
        case .generationFailed(let reason): return "Generation failed: \(reason)"
        case .tokenizationFailed: return "Tokenization failed"
        }
    }
}

// MARK: - Tool call parsing

struct ParsedToolCall: Codable {
    struct Inner: Codable {
        let name: String
        let arguments: JSONValue
    }
    // swiftlint:disable:next identifier_name
    let tool_call: Inner   // mirrors the model's JSON key verbatim
}

// MARK: - Model Factory

enum ModelFactory {
    static func makeModel() -> any LocalLanguageModel {
        #if DEBUG
        // Test-runner only: deterministic scripted responses for UI tests.
        // Never reachable from Settings; compiled out of release builds.
        if UserDefaults.standard.bool(forKey: "scripted_model") {
            return ScriptedModel()
        }
        #endif

        // Honor the user's choice (Settings → Model). Unknown ids fall back to
        // `.automatic`, which is today's exact priority chain — so users who
        // never open the manager get unchanged behavior.
        let selectedID = UserDefaults.standard.string(forKey: ModelManager.selectionKey) ?? "automatic"
        let selection = ModelCatalog.kind(forID: selectedID)

        switch selection {
        case .liteRT:
            return makeLiteRTLMModel()
                ?? UnavailableModel(reason: "Gemma 4 E4B (LiteRT-LM) isn't available in this build.")
        case .downloadable:
            return downloadedLiteRTLMModel(optionID: selectedID)
                ?? UnavailableModel(reason: "This model isn't downloaded yet. Download it in Settings → Model, or pick Automatic.")
        case .automatic:
            return makeAutomatic()
        }
    }

    /// Default priority chain. One engine, one family: Google's **LiteRT-LM**
    /// (the AI Edge Gallery runtime) running Gemma 4, on BOTH iOS and macOS.
    /// Bundled E4B → downloaded E4B → downloaded E2B → Unavailable.
    private static func makeAutomatic() -> any LocalLanguageModel {
        if let lite = makeLiteRTLMModel() { return lite }
        return UnavailableModel()
    }

    /// Gemma 4 via LiteRT-LM (Metal GPU on Mac, GPU on iOS) — the same engine
    /// the AI Edge Gallery apps use. Prefers a bundled `gemma4e4b.litertlm`
    /// when a build ships one, then falls back to whichever allowlist build has
    /// been downloaded (E4B before the lighter E2B). Available on both
    /// platforms whenever the LiteRT-LM package is linked.
    private static func makeLiteRTLMModel() -> (any LocalLanguageModel)? {
        #if canImport(LiteRTLM)
        if let bundled = Bundle.main.path(forResource: "gemma4e4b", ofType: "litertlm") {
            // The budget has to clear the agent's own prompt. A 2048 cap here
            // rejected every message with "Input token ids are too long"
            // (3056 >= 2048) — the system prompt plus tool descriptions alone
            // exceed it. `LiteRTLMModel`'s default matches the allowlist
            // config for these same weights, so don't undercut it.
            return LiteRTLMModel(modelPath: bundled, modelName: "Gemma 4 E4B (LiteRT-LM)")
        }
        for model in ModelCatalog.allowlist.models.sorted(by: { $0.sizeInBytes > $1.sizeInBytes }) {
            if let ready = downloadedLiteRTLMModel(
                optionID: ModelCatalog.downloadablePrefix + model.id) {
                return ready
            }
        }
        return nil
        #else
        return nil
        #endif
    }

    /// A downloaded allowlist model run through LiteRT-LM (Gallery-style),
    /// loaded from the file the download manager fetched, with the model's own
    /// `maxTokens` from its `defaultConfig`.
    private static func downloadedLiteRTLMModel(optionID: String) -> (any LocalLanguageModel)? {
        #if canImport(LiteRTLM)
        guard let model = ModelCatalog.allowlistModel(forOptionID: optionID) else { return nil }
        let store = ModelDownloadStore()
        guard store.isDownloaded(model) else { return nil }
        return LiteRTLMModel(modelPath: store.fileURL(for: model).path,
                             modelName: model.name, maxTokens: model.defaultConfig.maxTokens)
        #else
        return nil
        #endif
    }
}

/// Returned when the selected/automatic model can't run — every operation fails
/// loudly with a clear, specific message instead of silently faking responses.
struct UnavailableModel: LocalLanguageModel {
    let modelName = "No Model Available"
    private let reason: String

    init(reason: String = "No on-device model is available. Add gemma4e4b.litertlm to the bundle, or download Gemma 4 E2B/E4B in Settings → Model.") {
        self.reason = reason
    }

    func load() async throws {
        throw ModelError.modelLoadFailed(reason)
    }

    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String> {
        throw ModelError.modelLoadFailed(reason)
    }
}
