import Foundation
import CoreML

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
    let tool_call: Inner
}

// MARK: - Real Core ML Model

/// Wraps a Core ML .mlpackage for on-device inference
actor GemmaModel: LocalLanguageModel {
    private var mlModel: MLModel?
    private let tokenizer: any Tokenizer
    private let config: ModelConfig
    nonisolated let modelName: String

    private var _isLoaded = false
    // Actors are reentrant across awaits — a single in-flight task ensures
    // concurrent load() callers share one 2.3GB model load instead of stacking
    private var loadTask: Task<MLModel, Error>?

    init(config: ModelConfig = .gemma4B, tokenizer: any Tokenizer = FallbackTokenizer()) {
        self.config = config
        self.tokenizer = tokenizer
        self.modelName = config.modelName
    }

    func load() async throws {
        guard !_isLoaded else { return }

        if loadTask == nil {
            // Xcode compiles .mlpackage into .mlmodelc inside the app bundle
            guard let modelURL =
                Bundle.main.url(forResource: config.mlpackageName, withExtension: "mlmodelc") ??
                Bundle.main.url(forResource: config.mlpackageName, withExtension: "mlpackage") else {
                throw ModelError.modelNotFound(config.mlpackageName)
            }
            let mlConfig = MLModelConfiguration()
            mlConfig.computeUnits = .all // Use ANE + GPU + CPU
            loadTask = Task {
                try await MLModel.load(contentsOf: modelURL, configuration: mlConfig)
            }
        }

        do {
            mlModel = try await loadTask!.value
            _isLoaded = true
        } catch {
            loadTask = nil // allow retry on next call
            throw ModelError.modelLoadFailed(error.localizedDescription)
        }
    }

    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String> {
        // Load lazily if needed — a message sent while the model is still
        // loading waits for the in-flight load instead of erroring out
        try await load()
        guard let model = mlModel else {
            throw ModelError.modelLoadFailed("Model failed to load")
        }

        let inputTokens = tokenizer.encode(prompt)
        let eosId = tokenizer.eosTokenId
        let padId = tokenizer.padTokenId
        let seqLen = self.config.seqLen

        return AsyncStream<String> { continuation in
            let producer = Task {
                var generated: [Int] = []
                var currentTokens = inputTokens
                var decodedText = ""

                for _ in 0..<config.maxNewTokens {
                    if Task.isCancelled { break } // Stop button
                    // The converted model has a fixed input shape [1, seqLen].
                    // Left-pad so the last position holds the latest token; the
                    // attention mask zeroes out the padding.
                    let window = Array(currentTokens.suffix(seqLen))
                    let padCount = seqLen - window.count

                    guard let inputArray = try? MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32),
                          let maskArray = try? MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32) else {
                        continuation.finish()
                        return
                    }
                    for i in 0..<padCount {
                        inputArray[i] = NSNumber(value: padId)
                        maskArray[i] = 0
                    }
                    for (i, t) in window.enumerated() {
                        inputArray[padCount + i] = NSNumber(value: t)
                        maskArray[padCount + i] = 1
                    }

                    guard let provider = try? MLDictionaryFeatureProvider(dictionary: [
                        "input_ids": MLFeatureValue(multiArray: inputArray),
                        "attention_mask": MLFeatureValue(multiArray: maskArray)
                    ]) else {
                        continuation.finish()
                        return
                    }

                    guard let output = try? model.prediction(from: provider),
                          let logits = output.featureValue(for: "logits")?.multiArrayValue else {
                        continuation.finish()
                        return
                    }

                    let nextToken = sampleToken(from: logits, config: config, previous: generated)
                    if nextToken == eosId { break }

                    generated.append(nextToken)
                    currentTokens.append(nextToken)

                    let decoded = tokenizer.decode([nextToken])
                    decodedText += decoded

                    // Stop if the decoded text now ends with a stop sequence
                    if config.stopSequences.contains(where: { decodedText.hasSuffix($0) }) {
                        break
                    }
                    continuation.yield(decoded)
                }

                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    private func sampleToken(from logits: MLMultiArray, config: GenerationConfig, previous: [Int]) -> Int {
        // Get last token's logits
        let vocabSize = logits.shape.last?.intValue ?? 256000
        let totalElements = logits.count
        let offset = totalElements - vocabSize

        var scores = [Float](repeating: 0, count: vocabSize)
        for i in 0..<vocabSize {
            scores[i] = logits[offset + i].floatValue
        }

        // Repetition penalty: divide the logit of already-generated tokens
        // (CTRL-style — positive logits shrink, negative ones grow more negative).
        if config.repetitionPenalty != 1.0 {
            let penalty = config.repetitionPenalty
            for t in Set(previous) where t >= 0 && t < vocabSize {
                scores[t] = scores[t] > 0 ? scores[t] / penalty : scores[t] * penalty
            }
        }

        if config.temperature <= 0.01 {
            // Greedy
            return scores.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
        }

        // Temperature scaling
        let temp = config.temperature
        scores = scores.map { $0 / temp }

        // Softmax
        let maxScore = scores.max() ?? 0
        var expScores = scores.map { exp($0 - maxScore) }
        let sum = expScores.reduce(0, +)
        expScores = expScores.map { $0 / sum }

        // Combined top-k + top-p: rank, keep at most topK, stop at topP mass.
        let sorted = expScores.enumerated().sorted { $0.element > $1.element }
        let kLimit = config.topK > 0 ? config.topK : sorted.count
        var cumulative: Float = 0
        var topTokens: [(Int, Float)] = []
        for (idx, prob) in sorted {
            cumulative += prob
            topTokens.append((idx, prob))
            if topTokens.count >= kLimit || cumulative >= config.topP { break }
        }

        // Sample from top-p
        let rand = Float.random(in: 0..<1)
        var runningSum: Float = 0
        let topSum = topTokens.map(\.1).reduce(0, +)
        for (idx, prob) in topTokens {
            runningSum += prob / topSum
            if rand < runningSum { return idx }
        }
        return topTokens.first?.0 ?? 0
    }
}

// MARK: - Model Factory

enum ModelFactory {
    static func makeModel(config: ModelConfig = .gemma4B) -> any LocalLanguageModel {
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
        let selection = ModelCatalog.kind(
            forID: UserDefaults.standard.string(forKey: ModelManager.selectionKey) ?? "automatic")

        switch selection {
        case .appleFoundation:
            return makeAppleModel()
        case .liteRT:
            return makeLiteRTModel()
                ?? UnavailableModel(reason: "Gemma 4 E4B (LiteRT) isn't bundled in this build.")
        case .coreML:
            return makeCoreMLModel(config: config)
                ?? UnavailableModel(reason: "Gemma 3 4B (Core ML) isn't available on this device.")
        case .downloadable:
            return UnavailableModel(reason: "This model needs to be downloaded. Pick Automatic or a bundled model in Settings → Model.")
        case .privateCloud:
            return makePrivateCloudModel()
        case .automatic:
            return makeAutomatic(config: config)
        }
    }

    /// A backend that streams from the user's private compute server. Network
    /// backend — never auto-selected; an explicit Settings choice.
    private static func makePrivateCloudModel() -> any LocalLanguageModel {
        let client = PrivateComputeClient()
        guard client.isConfigured else {
            return UnavailableModel(reason: "No private server endpoint configured. Add one in Settings → Private Compute.")
        }
        return PrivateCloudModel(client: client)
    }

    /// Today's priority chain — the default: LiteRT → Core ML → Unavailable.
    private static func makeAutomatic(config: ModelConfig) -> any LocalLanguageModel {
        if let lite = makeLiteRTModel() { return lite }
        if let core = makeCoreMLModel(config: config) { return core }
        return UnavailableModel()
    }

    /// Gemma 4 E4B via Google's LiteRT engine (KV-cached). Present only when the
    /// engine is linked and the model file is bundled.
    private static func makeLiteRTModel() -> (any LocalLanguageModel)? {
        #if canImport(MediaPipeTasksGenAI)
        if Bundle.main.path(forResource: "gemma4e4b", ofType: "litertlm") != nil {
            return LiteRTGemmaModel()
        }
        #endif
        return nil
    }

    /// Gemma 3 4B via Core ML. The int4 .mlpackage uses per-block quantization,
    /// which Core ML only loads on iOS 18+.
    private static func makeCoreMLModel(config: ModelConfig) -> (any LocalLanguageModel)? {
        let modelPresent =
            Bundle.main.url(forResource: config.mlpackageName, withExtension: "mlpackage") != nil ||
            Bundle.main.url(forResource: config.mlpackageName, withExtension: "mlmodelc") != nil
        guard modelPresent, #available(iOS 18, *) else { return nil }
        let tokenizer: any Tokenizer
        if let tokenizerURL = Bundle.main.url(forResource: "tokenizer", withExtension: "json"),
           let real = try? GemmaTokenizer(contentsOf: tokenizerURL) {
            tokenizer = real
        } else {
            tokenizer = FallbackTokenizer()
        }
        return GemmaModel(config: config, tokenizer: tokenizer)
    }

    /// Apple's on-device model via FoundationModels — when the framework is in
    /// the build and the device supports it.
    private static func makeAppleModel() -> any LocalLanguageModel {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            return FoundationModelBackend()
        }
        #endif
        let reason: String
        if case .unsupported(let r) = FoundationModelSupport.availability {
            reason = r
        } else {
            reason = "Apple Intelligence isn't available on this device."
        }
        return UnavailableModel(reason: reason)
    }
}

/// Returned when the selected/automatic model can't run — every operation fails
/// loudly with a clear, specific message instead of silently faking responses.
struct UnavailableModel: LocalLanguageModel {
    let modelName = "No Model Available"
    private let reason: String

    init(reason: String = "No on-device model is bundled. Add gemma4e4b.litertlm (or gemma4b.mlpackage), or choose a model in Settings → Model.") {
        self.reason = reason
    }

    func load() async throws {
        throw ModelError.modelLoadFailed(reason)
    }

    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String> {
        throw ModelError.modelLoadFailed(reason)
    }
}
