import Foundation

#if canImport(MCP)
// The MCP SDK is kept out of GemmaAgent's public interface (`@_implementationOnly`)
// so the test target can `@testable import GemmaAgent` without linking the package
// — the same isolation pattern used for the MediaPipe LiteRT engine.
@_implementationOnly import MCP

/// Live connection to one remote MCP server (Streamable HTTP / JSON-RPC).
/// Connects lazily, lists tools, and proxies `tools/call`. All conversion to/from
/// the SDK's `Value`/`Tool.Content` goes through a JSON round-trip so we don't
/// depend on the SDK's exact enum shapes.
actor MCPConnection: MCPToolInvoking {
    private let config: MCPServerConfig
    private let client: Client
    private var connected = false
    /// Built once per connection (the SDK forbids sharing an authorizer across
    /// transports); only present for `.oauth` servers.
    private let authorizer: (any HTTPClientAuthorizer)?

    init(config: MCPServerConfig) {
        self.config = config
        self.client = Client(name: "GemmaAgent", version: "1.0.0")
        if case .oauth = config.auth {
            self.authorizer = makeOAuthAuthorizer(serverID: config.id)
        } else {
            self.authorizer = nil
        }
    }

    /// Connects (if needed) and returns the server's tools as our own type.
    /// Non-interactive connects are bounded by a timeout so a dead server can't
    /// hang refresh; interactive (OAuth sign-in) connects skip it because the
    /// user-driven browser sheet legitimately takes longer.
    func connectAndList(interactive: Bool = false) async throws -> [MCPToolInfo] {
        let work: @Sendable () async throws -> [MCPToolInfo] = {
            try await self.doConnect()
            let (tools, _) = try await self.client.listTools()
            return tools.map { tool in
                MCPToolInfo(
                    name: tool.name,
                    description: tool.description ?? "",
                    parameters: Self.schema(fromEncodable: tool.inputSchema)
                )
            }
        }
        return interactive ? try await work() : try await withMCPTimeout(seconds: 12, work)
    }

    func callTool(rawName: String, arguments: JSONValue) async throws -> String {
        try await withMCPTimeout(seconds: 30) {
            try await self.doConnect()
            let mcpArgs = try Self.toMCPArguments(arguments)
            let (content, isError) = try await self.client.callTool(name: rawName, arguments: mcpArgs)
            let text = Self.extractText(content)
            return (isError == true ? "[tool reported an error] " : "") + text
        }
    }

    // MARK: - Connection

    private func doConnect() async throws {
        guard !connected else { return }
        guard let url = URL(string: config.endpoint), url.scheme?.hasPrefix("http") == true else {
            throw MCPConnectionError.invalidURL
        }
        let transport: HTTPClientTransport
        switch config.auth {
        case .oauth:
            // The SDK's authorizer drives discovery, dynamic registration, PKCE,
            // the browser sign-in, and refresh.
            transport = HTTPClientTransport(endpoint: url, streaming: false, authorizer: authorizer)
        case .bearer(let token):
            transport = HTTPClientTransport(
                endpoint: url,
                streaming: false,
                requestModifier: { request in
                    var req = request
                    if !token.isEmpty {
                        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    return req
                }
            )
        case .none:
            transport = HTTPClientTransport(endpoint: url, streaming: false)
        }
        _ = try await client.connect(transport: transport)
        connected = true
    }

    // MARK: - Conversions (JSON round-trip — robust to the SDK's exact types)

    /// MCP `inputSchema` (an Encodable JSON value) → our `JSONSchema`.
    nonisolated static func schema(fromEncodable value: some Encodable) -> JSONSchema? {
        guard let data = try? JSONEncoder().encode(value),
              let jsonValue = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return nil
        }
        return MCPSchema.schema(from: jsonValue)
    }

    /// Our argument object → the SDK's `[String: Value]`.
    nonisolated static func toMCPArguments(_ args: JSONValue) throws -> [String: Value] {
        guard case .object = args else { return [:] }
        let data = try JSONEncoder().encode(args)
        return try JSONDecoder().decode([String: Value].self, from: data)
    }

    /// `[MCP.Tool.Content]` → a plain-text rendering (text blocks joined; non-text noted).
    nonisolated static func extractText(_ content: [MCP.Tool.Content]) -> String {
        guard let data = try? JSONEncoder().encode(content),
              let items = try? JSONDecoder().decode([JSONValue].self, from: data) else {
            return ""
        }
        var parts: [String] = []
        for item in items {
            if let text = item["text"]?.stringValue {
                parts.append(text)
            } else {
                parts.append("[non-text content omitted]")
            }
        }
        return parts.joined(separator: "\n")
    }
}

enum MCPConnectionError: Error, LocalizedError {
    case timeout
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .timeout: return "The MCP server did not respond in time."
        case .invalidURL: return "The MCP server URL is not a valid http(s) URL."
        }
    }
}

/// Races an operation against a timeout (the agent's `executeTool` timeout only
/// covers tool calls, not the connect/list during refresh).
private func withMCPTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw MCPConnectionError.timeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
#endif
