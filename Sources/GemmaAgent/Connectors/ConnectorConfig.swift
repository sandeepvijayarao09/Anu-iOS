import Foundation

// MARK: - Connector configurations

/// How a remote MCP server authenticates the agent.
enum MCPAuth: Sendable, Equatable, Codable {
    /// Open server — no credentials.
    case none
    /// Static bearer token sent as `Authorization: Bearer <token>`.
    case bearer(String)
    /// OAuth 2.1 (authorization-code + PKCE) handled by the SDK; the browser
    /// sign-in is deferred until the user explicitly connects.
    case oauth

    private enum CodingKeys: String, CodingKey { case type, token }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "bearer": self = .bearer(try c.decodeIfPresent(String.self, forKey: .token) ?? "")
        case "oauth": self = .oauth
        default: self = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none: try c.encode("none", forKey: .type)
        case .bearer(let t): try c.encode("bearer", forKey: .type); try c.encode(t, forKey: .token)
        case .oauth: try c.encode("oauth", forKey: .type)
        }
    }
}

/// A remote MCP server the agent can connect to (Streamable HTTP / JSON-RPC).
struct MCPServerConfig: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// HTTPS endpoint of the MCP server.
    var endpoint: String
    var auth: MCPAuth
    var enabled: Bool

    init(id: UUID = UUID(), name: String, endpoint: String, auth: MCPAuth = .none, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.auth = auth
        self.enabled = enabled
    }

    /// Stable slug used to namespace this server's tools (`mcp__<slug>__<tool>`).
    var slug: String { ConnectorSlug.make(name.isEmpty ? endpoint : name) }

    // Custom Codable so blobs written before the `auth` field (which stored a
    // top-level `authToken`) still decode and migrate on first load.
    private enum CodingKeys: String, CodingKey { case id, name, endpoint, auth, enabled, authToken }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        endpoint = try c.decode(String.self, forKey: .endpoint)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        if let a = try c.decodeIfPresent(MCPAuth.self, forKey: .auth) {
            auth = a
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .authToken), !legacy.isEmpty {
            auth = .bearer(legacy)
        } else {
            auth = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(endpoint, forKey: .endpoint)
        try c.encode(auth, forKey: .auth)
        try c.encode(enabled, forKey: .enabled)
    }
}

/// A user-defined REST endpoint exposed to the agent as a single tool.
struct RESTConnectorConfig: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// Base URL; the agent may append a `path` and `query`. Host is allowlisted.
    var baseURL: String
    /// HTTP method (GET, POST, …). Non-GET counts as a write (gated).
    var method: String
    /// Optional auth header, e.g. name "Authorization", value "Bearer …".
    var authHeaderName: String?
    var authHeaderValue: String?
    /// What the tool does, shown to the model.
    var toolDescription: String
    var enabled: Bool

    init(id: UUID = UUID(), name: String, baseURL: String, method: String = "GET",
         authHeaderName: String? = nil, authHeaderValue: String? = nil,
         toolDescription: String = "", enabled: Bool = true) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.method = method.uppercased()
        self.authHeaderName = authHeaderName
        self.authHeaderValue = authHeaderValue
        self.toolDescription = toolDescription
        self.enabled = enabled
    }

    var slug: String { ConnectorSlug.make(name.isEmpty ? baseURL : name) }
    var isWrite: Bool { method != "GET" && method != "HEAD" }
}

/// Controls whether the agent may launch other apps / run Shortcuts, and which
/// URL schemes are permitted.
struct AppLauncherConfig: Codable, Sendable, Equatable {
    var enabled: Bool
    var allowedSchemes: [String]

    static let `default` = AppLauncherConfig(
        enabled: false,
        allowedSchemes: ["shortcuts", "maps", "tel", "sms", "mailto", "music", "https"]
    )

    func allows(scheme: String) -> Bool {
        allowedSchemes.contains(scheme.lowercased())
    }
}

// MARK: - Slug helper

enum ConnectorSlug {
    /// Lowercased, alphanumeric+underscore, collapsed — safe inside a tool name.
    static func make(_ raw: String) -> String {
        let mapped = raw.lowercased().map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "_"
        }
        var slug = String(mapped)
        while slug.contains("__") { slug = slug.replacingOccurrences(of: "__", with: "_") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return slug.isEmpty ? "server" : slug
    }
}

// MARK: - Persistence (Keychain JSON blobs)

/// Loads/saves connector configs. `KeychainStore` is one-string-per-key, so each
/// config collection is stored as a single JSON blob (tokens included → Keychain).
enum ConnectorStore {
    private static let mcpKey = "connectors_mcp"
    private static let restKey = "connectors_rest"
    private static let appKey = "connectors_app"

    static func loadMCP() -> [MCPServerConfig] { decode(mcpKey) ?? [] }
    static func saveMCP(_ servers: [MCPServerConfig]) { encode(servers, mcpKey) }

    static func loadREST() -> [RESTConnectorConfig] { decode(restKey) ?? [] }
    static func saveREST(_ connectors: [RESTConnectorConfig]) { encode(connectors, restKey) }

    static func loadApp() -> AppLauncherConfig { decode(appKey) ?? .default }
    static func saveApp(_ config: AppLauncherConfig) { encode(config, appKey) }

    // MARK: Codable helpers

    private static func decode<T: Decodable>(_ key: String) -> T? {
        guard let json = KeychainStore.shared.string(forKey: key),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else { return }
        KeychainStore.shared.set(json, forKey: key)
    }
}

// MARK: - OAuth token storage (MCP-free wrapper)

/// Stores a Codable value as a JSON string in the Keychain. MCP-free so it
/// compiles in the test target and is unit-testable; `KeychainTokenStorage`
/// (behind `#if canImport(MCP)`) wraps it for the SDK's `TokenStorage`.
final class JSONKeychainBox<Value: Codable>: @unchecked Sendable {
    private let key: String
    init(key: String) { self.key = key }

    func save(_ value: Value) {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else { return }
        KeychainStore.shared.set(json, forKey: key)
    }

    func load() -> Value? {
        KeychainStore.shared.string(forKey: key)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    func clear() { KeychainStore.shared.remove(forKey: key) }
}

/// Keychain key for a server's OAuth token. Defined MCP-free so connect-time
/// checks and token clearing work everywhere (the SDK token type is MCP-only).
enum MCPOAuthToken {
    static func key(for serverID: UUID) -> String { "mcp_oauth_\(serverID.uuidString)" }
    static func exists(for serverID: UUID) -> Bool {
        !(KeychainStore.shared.string(forKey: key(for: serverID)) ?? "").isEmpty
    }
    static func clear(for serverID: UUID) {
        KeychainStore.shared.remove(forKey: key(for: serverID))
    }
}
