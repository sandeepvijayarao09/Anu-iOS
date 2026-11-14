import Foundation
import CoreGraphics

// MARK: - Protocol

/// Protocol for any local language model
protocol LocalLanguageModel: Sendable {
    var modelName: String { get }
    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String>
    /// Multimodal variant — vision-capable backends override this.
    func generate(prompt: String, image: CGImage?, config: GenerationConfig) async throws -> AsyncStream<String>
    /// Several pictures with the newest message (ADR-094), at most four.
    /// Vision backends override it; the default passes the first one on.
    func generate(prompt: String, images: [CGImage], config: GenerationConfig) async throws -> AsyncStream<String>
    func load() async throws
    /// Drops any cached per-conversation inference state (e.g. a KV cache).
    /// Called when switching sandboxes so one session's context can't leak into
    /// another. Stateless backends use the no-op default.
    func resetSession() async
    /// Whether this backend can turn on a reasoning ("thought") channel, as
    /// Gemma 4 on LiteRT-LM can (ADR-077). Backends that can't ignore
    /// `GenerationConfig.thinking`.
    var supportsThinking: Bool { get }
    /// What the runtime measured for the most recent finished generation, with
    /// any reasoning it produced (ADR-071, ADR-077). Nil when it can't say.
    func lastUsage() async -> GenerationUsage?
    /// The engine tokenizer's own count for `text`, for token calibration
    /// (ADR-041). Nil when the backend has no tokenizer to ask.
    func countTokens(_ text: String) async -> Int?
    /// What the backend is busy with before the first word (ADR-074), so a
    /// wait can say why. Backends that can't tell report `.idle`.
    func activity() async -> ModelActivity
    /// Warm start (ADR-074): get ready to answer without answering. Backends
    /// that load instantly use the no-op default.
    func warmUp() async
    /// The model's whole working space in tokens (instructions, tools, the
    /// chat kept, the message and the answer together). It sets how much of
    /// a chat is remembered (`ConversationWindow`).
    var contextTokens: Int { get }
}

/// What an on-device model is doing before it can answer (Android ADR-074).
enum ModelActivity: Equatable, Sendable {
    case idle
    /// Loading the model file into memory.
    case loading
    /// A GPU model's first run on this phone, which prepares its kernels.
    case settingUpGPU
    /// Building the conversation again from the chat, which reads all of it.
    case reading

    /// The line shown once a wait passes a second.
    func waitNote(modelName: String) -> String? {
        switch self {
        case .idle: return nil
        case .loading: return "Getting \(Self.shortName(modelName)) ready…"
        case .settingUpGPU: return "Setting up the GPU. First time only, about a minute."
        case .reading: return "Catching up on this chat…"
        }
    }

    /// "Gemma 4 E4B (LiteRT-LM)" → "Gemma 4 E4B".
    static func shortName(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s*\(.*\)\s*$"#, with: "", options: .regularExpression)
    }
}

extension LocalLanguageModel {
    /// Most backends can't tell what they're busy with.
    func activity() async -> ModelActivity { .idle }
    func warmUp() async {}
    /// A conservative default: Apple's first on-device model's size.
    var contextTokens: Int { 4_096 }

    /// Text-only backends ignore the image.
    func generate(prompt: String, image: CGImage?, config: GenerationConfig) async throws -> AsyncStream<String> {
        try await generate(prompt: prompt, config: config)
    }

    func generate(prompt: String, images: [CGImage], config: GenerationConfig) async throws -> AsyncStream<String> {
        try await generate(prompt: prompt, image: images.first, config: config)
    }

    /// Stateless backends keep no per-conversation state, so there's nothing to reset.
    func resetSession() async {}

    var supportsThinking: Bool { false }
    func lastUsage() async -> GenerationUsage? { nil }
    func countTokens(_ text: String) async -> Int? { nil }
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
        // Your own model file (Settings → Model → Install from a File).
        if CustomModels.isCustom(selectedID) {
            #if canImport(LiteRTLM)
            if let url = CustomModels.fileURL(for: selectedID),
               FileManager.default.fileExists(atPath: url.path) {
                return LiteRTLMModel(modelPath: url.path, modelName: (url.lastPathComponent as NSString).deletingPathExtension)
            }
            #endif
            return UnavailableModel(reason: "That model file isn't on this device any more. Pick another in Settings → Model.")
        }
        let selection = ModelCatalog.kind(forID: selectedID)

        switch selection {
        case .appleOnDevice:
            let apple = AppleModels.status(of: .onDevice)
            switch BaseTierResolver.resolve(selection: .appleOnDevice, apple: apple, gemmaReady: false) {
            case .apple: return makeAppleModel() ?? UnavailableModel(reason: appleUnavailableReason())
            case .gemma, .unavailable: return UnavailableModel(reason: appleUnavailableReason())
            }
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

    /// Default priority chain (parity A1): Apple's on-device model when this
    /// device can run it, else Google's **LiteRT-LM** (the AI Edge Gallery
    /// runtime) running Gemma 4, on BOTH iOS and macOS: bundled E4B →
    /// downloaded E4B → downloaded E2B → Unavailable. With no on-device model
    /// at all, the router sends turns to a configured cloud provider.
    private static func makeAutomatic() -> any LocalLanguageModel {
        #if targetEnvironment(simulator)
        // The simulator reports Apple's model available but has no model files
        // for it (every turn fails with a model catalog error), so Automatic
        // uses Gemma there when a build has it.
        if let gemma = makeLiteRTLMModel() { return gemma }
        #endif
        let apple = AppleModels.status(of: .onDevice)
        let lite = apple.isUsable ? nil : makeLiteRTLMModel()
        switch BaseTierResolver.resolve(selection: .automatic, apple: apple, gemmaReady: lite != nil) {
        case .apple: return makeAppleModel() ?? makeLiteRTLMModel() ?? UnavailableModel()
        case .gemma: return lite ?? UnavailableModel()
        case .unavailable(let reason): return UnavailableModel(reason: reason)
        }
    }

    /// Apple's on-device model behind `LocalLanguageModel`, or nil when the
    /// OS, device, Apple Intelligence setting or model download says no.
    private static func makeAppleModel() -> (any LocalLanguageModel)? {
        guard AppleModels.status(of: .onDevice).isUsable else { return nil }
        #if canImport(FoundationModels) && compiler(>=6.4)  // iOS 27 SDK APIs (Xcode 27)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            return AppleFoundationModel(kind: .onDevice)
        }
        #endif
        return nil
    }

    private static func appleUnavailableReason() -> String {
        let why = AppleModels.status(of: .onDevice).reason?.userText ?? AppleModelUnavailableReason.frameworkMissing.userText
        return "Apple on-device isn't available. \(why) Pick Gemma 4 or Automatic in Settings → Model."
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
        return LiteRTLMModel(modelPath: store.fileURL(for: model).path, modelName: model.name)
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

    static let defaultReason = "No on-device model is available. Add gemma4e4b.litertlm to the bundle, or download Gemma 4 E2B/E4B in Settings → Model."

    init(reason: String = UnavailableModel.defaultReason) {
        self.reason = reason
    }

    func load() async throws {
        throw ModelError.modelLoadFailed(reason)
    }

    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String> {
        throw ModelError.modelLoadFailed(reason)
    }
}
