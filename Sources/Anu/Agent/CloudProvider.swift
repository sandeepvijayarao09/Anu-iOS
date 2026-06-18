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

    static let preferenceKey = "cloud_provider"

    static var preference: CloudProvider {
        CloudProvider(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "auto") ?? .auto
    }

    static var privateConfigured: Bool {
        !(KeychainStore.shared.string(forKey: "pcs_endpoint") ?? "").isEmpty
    }

    static var geminiConfigured: Bool {
        !(KeychainStore.shared.string(forKey: "gemini_api_key") ?? "").isEmpty
    }

    /// The provider that should handle escalation right now, or `nil` for
    /// local-only. In `auto`, private wins when configured.
    static func resolved() -> CloudProvider? {
        switch preference {
        case .privateCloud: return privateConfigured ? .privateCloud : nil
        case .gemini:       return geminiConfigured ? .gemini : nil
        case .auto:         return privateConfigured ? .privateCloud : (geminiConfigured ? .gemini : nil)
        }
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
