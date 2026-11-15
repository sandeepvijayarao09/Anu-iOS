import Foundation

/// Configuration for text generation
struct GenerationConfig: Sendable {
    var maxNewTokens: Int
    var temperature: Float
    var topP: Float
    var topK: Int
    var repetitionPenalty: Float
    var stopSequences: [String]
    /// Turn on the model's reasoning channel where the backend supports it
    /// (ADR-077). Off unless Settings → Think before answering is on.
    var thinking: Bool = false

    /// This config with thinking set from Settings → Think before answering.
    func applyingThinkingSetting(_ defaults: UserDefaults = .standard) -> GenerationConfig {
        var config = self
        config.thinking = defaults.bool(forKey: ThinkingSetting.key)
        return config
    }

    /// Where a turn ends: Gemma 3's markers and Gemma 4's (`<turn|>`), as a
    /// backstop for the engine's own end-of-turn stop.
    static let turnEnds = ["<end_of_turn>", "<eos>", "<turn|>", "<|turn>"]

    static let `default` = GenerationConfig(
        maxNewTokens: 384,
        temperature: 0.7,
        topP: 0.9,
        topK: 50,
        repetitionPenalty: 1.1,
        stopSequences: GenerationConfig.turnEnds
    )

    /// A chat turn: the agent's sampling, shorter. One sampler for both
    /// routes, so moving between them keeps the engine's cached chat (a new
    /// sampler means a new Conversation, which re-reads the whole chat).
    static var chat: GenerationConfig {
        var config = agentFromSettings
        config.maxNewTokens = 256
        return config
    }

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
        stopSequences: GenerationConfig.turnEnds
    )
}
