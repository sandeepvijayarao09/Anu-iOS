import Foundation
import os

/// Which cloud backend handles escalation. The private compute server is the
/// privacy-preferred path (operator-controlled); Gemini remains a fallback so
/// existing users aren't regressed. Resolved by one function used by BOTH the
/// classifier and the orchestrator so routing and execution never disagree.
enum CloudProvider: String, Sendable {
    case auto
    case privateCloud = "private"
    case gemini
    /// The user's own Mac running Ollama (ADR-113).
    case mac

    static let preferenceKey = "cloud_provider"

    static var preference: CloudProvider {
        CloudProvider(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "auto") ?? .auto
    }

    static var privateConfigured: Bool {
        !(KeychainStore.shared.string(forKey: "pcs_endpoint") ?? "").isEmpty
    }

    static var geminiConfigured: Bool {
        Vault.shared.contains(.gemini)
    }

    static var macConfigured: Bool {
        MacBrainConfig.load() != nil
    }

    /// The provider that should handle escalation right now, or `nil` for
    /// local-only. In `auto`: private, then the user's Mac (in Gemini's place
    /// while one is set up, as on Android), then Gemini.
    static func resolved() -> CloudProvider? {
        switch preference {
        case .privateCloud: return privateConfigured ? .privateCloud : nil
        case .gemini:       return geminiConfigured ? .gemini : nil
        case .mac:          return macConfigured ? .mac : nil
        case .auto:
            if privateConfigured { return .privateCloud }
            if macConfigured { return .mac }
            return geminiConfigured ? .gemini : nil
        }
    }

    /// The escalation tool that carries a turn to this provider.
    var escalationToolName: String {
        switch self {
        case .privateCloud: return "escalate_to_private_cloud"
        case .mac: return "escalate_to_mac"
        case .gemini, .auto: return "escalate_to_gemini"
        }
    }

    /// How the chat names where a redacted request went.
    var targetName: String {
        switch self {
        case .privateCloud: return "your private server"
        case .mac: return "your Mac"
        case .gemini, .auto: return "the cloud"
        }
    }

    /// The literal prefix this provider's escalation tool puts on an answer.
    var responsePrefix: String {
        switch self {
        case .privateCloud: return Self.responsePrefix(usingPrivate: true)
        case .mac: return "[Your Mac Response]\n\n"
        case .gemini, .auto: return Self.responsePrefix(usingPrivate: false)
        }
    }

    /// LEADING-only, like `stripResponsePrefix(_:usingPrivate:)`.
    func stripResponsePrefix(_ result: String) -> String {
        let body = result.hasPrefix(responsePrefix) ? String(result.dropFirst(responsePrefix.count)) : result
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The literal prefix each escalation tool prepends to a successful answer
    /// (`EscalateToGeminiTool` / `EscalateToPrivateCloudTool`).
    static func responsePrefix(usingPrivate: Bool) -> String {
        usingPrivate ? "[Private Compute Response]\n\n" : "[Gemini Response]\n\n"
    }

    /// Removes the provider's response prefix from a tool result for display.
    /// LEADING-only: a prefix that happens to appear inside the model's own body
    /// is left intact (a global replace would corrupt such responses).
    static func stripResponsePrefix(_ result: String, usingPrivate: Bool) -> String {
        let prefix = responsePrefix(usingPrivate: usingPrivate)
        let body = result.hasPrefix(prefix) ? String(result.dropFirst(prefix.count)) : result
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Thread-safe holder for the active sandbox id so off-main tool code (the
/// escalation tool runs off the main actor) can read it without touching the
/// `@MainActor` orchestrator.
final class ActiveSessionRef: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: "default")
    func get() -> String { storage.withLock { $0 } }
    func set(_ value: String) { storage.withLock { $0 = value } }
}
