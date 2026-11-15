import Foundation

/// Discovers a merchant's MCP endpoint so the agent can use its shopping tools
/// (product search, product details, cart, store policies…). Two paths, tried
/// in order:
///
///   1. **Universal Commerce Protocol** — fetch `/.well-known/ucp` and look for a
///      service whose transport is MCP (Google's open standard; ucp.dev).
///   2. **Shopify Agentic Storefront** (`/api/mcp`) — the convention millions of
///      merchants (a UCP launch partner) expose today. Used only when the
///      endpoint actually answers an MCP `initialize`.
///
/// Auth is detected by probing, not assumed: an endpoint that serves `initialize`
/// openly is added as `.none` (Shopify storefronts browse without sign-in); one
/// that returns 401/403 is added as `.oauth`. Checkout / payments (AP2) are out
/// of scope — this surfaces browse/read tools.
///
/// Plain URLSession + Codable, MCP-free (so it stays in the test target), with an
/// injectable session.
struct UCPDiscovery {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    /// How an endpoint answered our MCP `initialize` probe.
    enum Reachability { case mcp, needsAuth, notMCP }

    /// Resolves a merchant domain to a ready-to-add MCP server, or `nil` if the
    /// merchant exposes no agentic-commerce MCP endpoint.
    func discover(merchantDomain: String) async throws -> MCPServerConfig? {
        guard let host = Self.host(from: merchantDomain) else { return nil }

        // 1) UCP well-known: an explicit MCP service binding wins.
        if let endpoint = await wellKnownMCPEndpoint(host: host) {
            let auth: MCPAuth = (await probe(endpoint) == .needsAuth) ? .oauth : .none
            return MCPServerConfig(name: "\(host) (UCP)", endpoint: endpoint, auth: auth)
        }

        // 2) Shopify Agentic Storefront convention — only if it speaks MCP.
        let storefront = "https://\(host)/api/mcp"
        switch await probe(storefront) {
        case .mcp:       return MCPServerConfig(name: "\(host) (Shopping)", endpoint: storefront, auth: .none)
        case .needsAuth: return MCPServerConfig(name: "\(host) (Shopping)", endpoint: storefront, auth: .oauth)
        case .notMCP:    return nil
        }
    }

    // MARK: - Well-known fetch

    private func wellKnownMCPEndpoint(host: String) async -> String? {
        guard let url = URL(string: "https://\(host)/.well-known/ucp"),
              let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        return Self.parseMCPEndpoint(from: data)
    }

    // MARK: - MCP probe (raw JSON-RPC over HTTP — no MCP SDK)

    /// Sends a minimal `initialize` and classifies the response. Keeps this file
    /// MCP-free; the real connection (via the SDK) happens later in `refresh()`.
    private func probe(_ endpoint: String) async -> Reachability {
        guard let url = URL(string: endpoint), url.scheme?.lowercased() == "https" else { return .notMCP }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.initializeRequest.utf8)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .notMCP }
        if http.statusCode == 401 || http.statusCode == 403 { return .needsAuth }
        guard (200..<300).contains(http.statusCode) else { return .notMCP }
        return Self.isInitializeResult(data) ? .mcp : .notMCP
    }

    private static let initializeRequest =
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Anu","version":"1.0"}}}"#

    /// True if `data` carries a JSON-RPC `initialize` result (raw JSON or an SSE
    /// `data:` frame), recognized by `protocolVersion`/`serverInfo`/`capabilities`.
    static func isInitializeResult(_ data: Data) -> Bool {
        for value in jsonFrames(data) {
            guard let result = value["result"], case .object = result else { continue }
            if result["protocolVersion"] != nil || result["serverInfo"] != nil || result["capabilities"] != nil {
                return true
            }
        }
        return false
    }

    /// Decodes the body as JSON, or as the JSON payloads of any SSE `data:` lines.
    private static func jsonFrames(_ data: Data) -> [JSONValue] {
        if let whole = try? JSONDecoder().decode(JSONValue.self, from: data) { return [whole] }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var frames: [JSONValue] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let json = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) { frames.append(value) }
        }
        return frames
    }

    // MARK: - URL helpers

    /// Bare host from a bare domain or a full URL the user typed (drops the
    /// scheme and any path).
    static func host(from raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return nil }
        s = s.replacingOccurrences(of: "https://", with: "")
             .replacingOccurrences(of: "http://", with: "")
        s = s.split(separator: "/").first.map(String.init) ?? s
        return s.isEmpty ? nil : s
    }

    /// Builds the well-known URL from a bare domain or a full URL the user typed.
    static func wellKnownURL(forDomain raw: String) -> URL? {
        guard let host = host(from: raw) else { return nil }
        return URL(string: "https://\(host)/.well-known/ucp")
    }

    // MARK: - Tolerant discovery-doc parsing (the UCP doc nests services deeply)

    /// Searches a UCP discovery document for an MCP service binding's endpoint,
    /// regardless of exact nesting. MCP-free (decodes to our `JSONValue`).
    static func parseMCPEndpoint(from data: Data) -> String? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return find(root)
    }

    private static func find(_ value: JSONValue) -> String? {
        switch value {
        case .object(let obj):
            // A service/binding object that names mcp and carries an endpoint,
            // e.g. { "transport": "mcp", "endpoint": "https://…" }.
            let kind = (obj["transport"]?.stringValue
                        ?? obj["type"]?.stringValue
                        ?? obj["protocol"]?.stringValue ?? "").lowercased()
            if kind.contains("mcp"), let u = url(in: .object(obj)) { return u }
            // A keyed binding, e.g. { "mcp": "https://…" } or { "mcp": { "endpoint": … } }.
            if let mcp = obj["mcp"], let u = url(in: mcp) { return u }
            // Otherwise recurse (services live under ucp.services.<ns>[…]).
            for (_, v) in obj { if let found = find(v) { return found } }
            return nil
        case .array(let arr):
            for v in arr { if let found = find(v) { return found } }
            return nil
        default:
            return nil
        }
    }

    /// Extracts an https URL from a string value or an `endpoint`/`url`/`uri` field.
    private static func url(in value: JSONValue) -> String? {
        if let s = value.stringValue, s.lowercased().hasPrefix("https://") { return s }
        if case .object(let o) = value {
            for key in ["endpoint", "url", "uri"] {
                if let s = o[key]?.stringValue, s.lowercased().hasPrefix("https://") { return s }
            }
        }
        return nil
    }
}
