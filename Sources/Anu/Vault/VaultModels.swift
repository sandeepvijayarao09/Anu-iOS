import Foundation

// Vault types (Android parity: ARCHITECTURE §11, ADR-021, ADR-135).
//
// Code and models deal only in `SecretRef` handles (P3). A request asks for a
// secret with a `SecretUse`; only `Vault.authorize` turns that into a header,
// and only for HTTPS to one of the item's bound hosts, from an allowed caller
// (I1). No tool ever returns a secret value.

/// A handle to a vault item. Its description never contains the value.
struct SecretRef: Hashable, Codable, Sendable, CustomStringConvertible {
    let id: String
    init(_ id: String) { self.id = id }
    var description: String { "SecretRef(\(id))" }

    /// The user's Gemini API key, sent only to Google's Generative Language API.
    static let gemini = SecretRef("gemini_api_key")
    /// The Brave Search key used by `web_search`.
    static let braveSearch = SecretRef("search_api_key")
    /// Gmail's short-lived access token, sent only to the Gmail API.
    static let gmailAccess = SecretRef("gmail.access_token")
    /// Gmail's refresh token, sent only to Google's OAuth token endpoint.
    static let gmailRefresh = SecretRef("gmail.refresh_token")
}

/// Who may use a secret. Callers name themselves when they ask the vault.
enum VaultCaller {
    static let gemini = "gemini"
    static let webSearch = "web_search"
    static let connectors = "connectors"
    static let gmail = "gmail"
}

/// Asks the vault to attach `ref` as `header` ("<scheme> <value>" when a scheme is set).
struct SecretUse: Sendable, Equatable {
    let ref: SecretRef
    let header: String
    let caller: String
    var scheme: String? = nil
}

enum VaultItemKind: String, Codable, CaseIterable, Sendable {
    case apiKey, oauthToken, password, appPassword, secureNote

    var title: String {
        switch self {
        case .apiKey: return "API key"
        case .oauthToken: return "Sign-in token"
        case .password: return "Password"
        case .appPassword: return "App password"
        case .secureNote: return "Secure note"
        }
    }

    /// Only machine credentials may skip Face ID on use, so background work
    /// (workflows, the brief) can still call an API.
    var mayUseWithoutPresence: Bool { self == .apiKey || self == .oauthToken }
}

/// How an item unlocks.
enum VaultProtection: String, Codable, Sendable {
    /// Usable whenever the phone is unlocked. API keys and tokens only.
    case deviceUnlocked
    /// Needs Face ID / Touch ID / passcode each time it's read.
    case userPresence

    var title: String {
        switch self {
        case .deviceUnlocked: return "When the phone is unlocked"
        case .userPresence: return "With Face ID or your passcode"
        }
    }
}

/// An item's metadata. The value itself is never part of this struct, so
/// printing, logging or encoding a `VaultItem` can't leak it.
struct VaultItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var kind: VaultItemKind
    var label: String
    /// Human name of the service ("Gemini", "Brave Search").
    var service: String
    /// The only hosts the value may be sent to. Empty = never sent anywhere.
    var boundHosts: [String]
    /// Callers (see `VaultCaller`) allowed to use it.
    var allowedUsers: [String]
    var protection: VaultProtection
    var createdAt: Date
    var lastUsedAt: Date?

    var ref: SecretRef { SecretRef(id) }

    /// Canonical string binding the fields that decide where a value may go.
    /// Stored next to the value; if the metadata is edited to point a secret
    /// elsewhere, the two stop matching and use is refused.
    var binding: String {
        [id, kind.rawValue, protection.rawValue,
         boundHosts.map { $0.lowercased() }.sorted().joined(separator: ","),
         allowedUsers.sorted().joined(separator: ",")].joined(separator: "|")
    }

    var destinationSummary: String {
        boundHosts.isEmpty ? "Never sent" : "Sent only to " + boundHosts.joined(separator: ", ")
    }
}

enum VaultError: Error, Equatable, LocalizedError {
    case notFound(String)
    case locked
    case insecureScheme
    case hostNotBound(String)
    case callerNotAllowed(String)
    case bindingMismatch
    case protectionNotAllowed
    case storage(Int32)

    var errorDescription: String? {
        switch self {
        case .notFound(let id): return "No vault item named \(id)."
        case .locked: return "The vault needs Face ID or your passcode."
        case .insecureScheme: return "Secrets are only sent over HTTPS."
        case .hostNotBound(let host): return "This secret isn't allowed to go to \(host)."
        case .callerNotAllowed(let caller): return "\(caller) isn't allowed to use this secret."
        case .bindingMismatch: return "This vault item was changed outside Anu, so it won't be used."
        case .protectionNotAllowed: return "Only API keys and tokens can unlock without Face ID."
        case .storage(let status): return "The Keychain refused the change (\(status))."
        }
    }
}

/// One use, or refused use, of a vault item. Never holds the value.
struct VaultActivity: Codable, Identifiable, Hashable, Sendable {
    enum Outcome: String, Codable, Sendable { case sent, refused, shown, added, deleted }
    var id = UUID()
    let date: Date
    let itemID: String
    let label: String
    let caller: String
    let host: String?
    let outcome: Outcome
    var reason: String? = nil
}
