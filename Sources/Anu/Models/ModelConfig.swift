import Foundation

/// Configuration for text generation
struct GenerationConfig: Sendable {
    var maxNewTokens: Int
    var temperature: Float
    var topP: Float
    var topK: Int
    var repetitionPenalty: Float
    var stopSequences: [String]

    static let `default` = GenerationConfig(
        maxNewTokens: 384,
        temperature: 0.7,
        topP: 0.9,
        topK: 50,
        repetitionPenalty: 1.1,
        stopSequences: ["<end_of_turn>", "<eos>"]
    )

    /// Warm sampling for casual conversation: natural variety, short replies.
    static let chat = GenerationConfig(
        maxNewTokens: 256,
        temperature: 0.75,
        topP: 0.95,
        topK: 64,
        repetitionPenalty: 1.1,
        stopSequences: ["<end_of_turn>", "<eos>"]
    )

    /// Reads user-tunable values (temperature, max tokens) from Settings.
    static var fromSettings: GenerationConfig {
        var config = GenerationConfig.default
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "temperature") != nil {
            config.temperature = Float(defaults.double(forKey: "temperature"))
        }
        let maxTokens = defaults.integer(forKey: "max_tokens")
        if maxTokens > 0 {
            config.maxNewTokens = maxTokens
        }
        return config
    }

    /// Settings-derived config with temperature clamped for tool-calling
    /// discipline (agent mode needs reliable JSON, not creativity).
    static var agentFromSettings: GenerationConfig {
        var config = fromSettings
        config.temperature = min(config.temperature, 0.45)
        return config
    }

    static let deterministic = GenerationConfig(
        maxNewTokens: 512,
        temperature: 0.1,
        topP: 0.95,
        topK: 10,
        repetitionPenalty: 1.05,
        stopSequences: ["<end_of_turn>", "<eos>"]
    )
}

/// Overall model configuration
struct ModelConfig {
    var modelName: String
    var contextLength: Int
    var vocabSize: Int
    var hiddenSize: Int
    var numLayers: Int
    var numHeads: Int
    var mlpackageName: String
    /// Fixed sequence length the Core ML model was converted with
    /// (must match --seq_len passed to convert_gemma_coreml.py)
    var seqLen: Int

    static let gemma4B = ModelConfig(
        modelName: "Gemma 4B Instruct",
        contextLength: 8192,
        vocabSize: 262144,
        hiddenSize: 2560,
        numLayers: 34,
        numHeads: 8,
        mlpackageName: "gemma4b",
        seqLen: 512
    )
}
