import Foundation
import os

/// The two kinds of text whose tokens Anu estimates at different rates
/// (ADR-041): prose, and JSON (tool definitions, tool calls and results).
enum TokenTextKind: String, CaseIterable, Sendable {
    case prose
    case json

    /// Raw estimates are on the safe side: prose at 3.5 characters a token,
    /// JSON at 2.5 (braces, quotes and keys tokenize densely).
    var rawCharsPerToken: Double {
        switch self {
        case .prose: return 3.5
        case .json: return 2.5
        }
    }
}

/// One measurement: the raw estimate of exactly what was sent and generated,
/// against the runtime's own count of the same text.
struct TokenSample: Sendable, Equatable {
    let kind: TokenTextKind
    let estimated: Int
    let counted: Int
}

/// Learns how far the raw character estimates are from the on-device model's
/// real token counts, with a separate rate for prose and for JSON, and keeps
/// both across launches (ADR-041). Context budgets multiply raw estimates by
/// `scale(for:)`.
///
/// Only on-device counts are used: the cloud's tokenizer isn't the one the
/// on-device budgets are for. The ratios are plain numbers, not personal data,
/// so they live in UserDefaults like the Android app's settings.
final class TokenCalibration: @unchecked Sendable {
    static let shared = TokenCalibration(defaults: .standard)

    /// How much each new turn moves a ratio.
    static let smoothing = 0.3
    static let minRatio = 0.5
    static let maxRatio = 2.5
    /// Small samples are noisy: the chat template's fixed markers weigh too much in them.
    static let minEstimate = 200
    /// Covers what a learned ratio can't know yet. Applied only once learned,
    /// so an uncalibrated budget is exactly the raw estimate.
    static let margin = 1.05

    private struct State {
        var ratios: [TokenTextKind: Double] = [:]
    }
    private let state: OSAllocatedUnfairLock<State>
    private let defaults: UserDefaults?

    /// - Parameter defaults: where the ratios persist; nil keeps them in memory (tests).
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        var initial = State()
        for kind in TokenTextKind.allCases {
            if let saved = defaults?.object(forKey: Self.key(kind)) as? Double {
                initial.ratios[kind] = min(max(saved, Self.minRatio), Self.maxRatio)
            }
        }
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    static func key(_ kind: TokenTextKind) -> String { "token_ratio_\(kind.rawValue)" }

    /// The learned ratio of counted to raw-estimated tokens; nil until learned.
    func ratio(for kind: TokenTextKind) -> Double? {
        state.withLock { $0.ratios[kind] }
    }

    /// What raw estimates of `kind` are multiplied by.
    func scale(for kind: TokenTextKind) -> Double {
        guard let ratio = ratio(for: kind) else { return 1.0 }
        return ratio * Self.margin
    }

    /// The raw estimate: characters over the kind's fixed rate, rounded up.
    static func rawEstimate(_ text: String, kind: TokenTextKind) -> Int {
        guard !text.isEmpty else { return 0 }
        return Int((Double(text.count) / kind.rawCharsPerToken).rounded(.up))
    }

    /// The calibrated estimate the context budget uses.
    func estimate(_ text: String, kind: TokenTextKind) -> Int {
        Int((Double(Self.rawEstimate(text, kind: kind)) * scale(for: kind)).rounded(.up))
    }

    /// Estimate for mixed text: each line counted as prose or JSON.
    func estimate(_ text: String) -> Int {
        let parts = Self.split(text)
        return estimate(parts.prose, kind: .prose) + estimate(parts.json, kind: .json)
    }

    /// Records one on-device measurement. The first sample of a kind sets its
    /// ratio; later ones move it by `smoothing`.
    func observe(_ sample: TokenSample) {
        guard sample.estimated >= Self.minEstimate, sample.counted > 0 else { return }
        let observed = min(max(Double(sample.counted) / Double(sample.estimated), Self.minRatio), Self.maxRatio)
        let updated: Double = state.withLock { s in
            let next = s.ratios[sample.kind].map { $0 + Self.smoothing * (observed - $0) } ?? observed
            s.ratios[sample.kind] = next
            return next
        }
        defaults?.set(updated, forKey: Self.key(sample.kind))
    }

    /// Forgets what was learned (both kinds).
    func reset() {
        state.withLock { $0.ratios = [:] }
        for kind in TokenTextKind.allCases { defaults?.removeObject(forKey: Self.key(kind)) }
    }

    // MARK: - Splitting text by kind

    /// Splits text into its prose and JSON lines. A line is JSON when, trimmed,
    /// it starts with `{`, `[`, `}` or `]`, or holds a `"key":` pair — tool
    /// definitions, tool calls and results look like that; prose rarely does.
    static func split(_ text: String) -> (prose: String, json: String) {
        var prose: [Substring] = []
        var json: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if isJSONLine(line) { json.append(line) } else { prose.append(line) }
        }
        return (prose.joined(separator: "\n"), json.joined(separator: "\n"))
    }

    static func isJSONLine(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return false }
        if "{[]}".contains(first) { return true }
        return trimmed.range(of: #""[A-Za-z_][A-Za-z0-9_]*"\s*:"#, options: .regularExpression) != nil
    }

    /// The kind a chat message's text is budgeted as.
    static func kind(of message: AgentMessage) -> TokenTextKind {
        switch message.role {
        case .toolCall, .toolResult: return .json
        case .user, .assistant, .system: return .prose
        }
    }

    // MARK: - Learning from a turn

    /// Measures `text` (a prompt plus what was generated) with the model's own
    /// tokenizer, kind by kind, and learns from it. Does nothing for backends
    /// without a tokenizer (the cloud, the scripted test model).
    /// How much of a prompt one turn samples (about 1,500 tokens).
    static let sampleChars = 6_000

    func learn(from text: String, model: any LocalLanguageModel) async {
        let parts = Self.split(text)
        for (kind, piece) in [(TokenTextKind.prose, parts.prose), (.json, parts.json)] {
            let estimated = Self.rawEstimate(piece, kind: kind)
            guard estimated >= Self.minEstimate, let counted = await model.countTokens(piece) else { continue }
            observe(TokenSample(kind: kind, estimated: estimated, counted: counted))
        }
    }
}
