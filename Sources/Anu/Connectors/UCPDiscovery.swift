import Foundation

/// Discovers a merchant's MCP endpoint via Google's Universal Commerce Protocol
/// (`/.well-known/ucp`). Read-only: it surfaces the merchant's MCP binding so the
/// agent can use its product/search tools. Checkout/payments (AP2) are out of
/// scope. Plain URLSession + Codable, MCP-free, injectable session.
struct UCPDiscovery {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    /// Fetches `https://<domain>/.well-known/ucp` and extracts an MCP binding
    /// endpoint. Returns `nil` (not an error) when the merchant has no MCP
    /// binding, so the UI can say so clearly. UCP merchants gate behind their own
    /// OAuth, so the produced config uses `.oauth`.
    func discover(merchantDomain: String) async throws -> MCPServerConfig? {
        guard let url = Self.wellKnownURL(forDomain: merchantDomain) else { return nil }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        guard let endpoint = Self.parseMCPEndpoint(from: data) else { return nil }
        let host = URL(string: endpoint)?.host ?? merchantDomain
        return MCPServerConfig(name: "\(host) (UCP)", endpoint: endpoint, auth: .oauth)
    }

    /// Builds the well-known URL from a bare domain or a full URL the user typed.
    static func wellKnownURL(forDomain raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        s = s.replacingOccurrences(of: "https://", with: "")
             .replacingOccurrences(of: "http://", with: "")
        s = s.split(separator: "/").first.map(String.init) ?? s   // drop any path
        guard !s.isEmpty else { return nil }
        return URL(string: "https://\(s)/.well-known/ucp")
    }

    // MARK: - Tolerant parsing (the UCP spec is new/sparse)

    /// Searches a UCP discovery document for an MCP binding's endpoint URL,
    /// regardless of exact nesting. MCP-free (decodes to our `JSONValue`).
    static func parseMCPEndpoint(from data: Data) -> String? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return find(root)
    }

    private static func find(_ value: JSONValue) -> String? {
        switch value {
        case .object(let obj):
            // A binding object that names mcp and carries a URL.
            let kind = (obj["transport"]?.stringValue
                        ?? obj["type"]?.stringValue
                        ?? obj["protocol"]?.stringValue ?? "").lowercased()
            if kind.contains("mcp"), let u = url(in: .object(obj)) { return u }
            // A keyed binding, e.g. { "mcp": "https://…" } or { "mcp": { "url": … } }.
            if let mcp = obj["mcp"], let u = url(in: mcp) { return u }
            // Otherwise recurse.
            for (_, v) in obj { if let found = find(v) { return found } }
            return nil
        case .array(let arr):
            for v in arr { if let found = find(v) { return found } }
            return nil
        default:
            return nil
        }
    }

    /// Extracts an http(s) URL from a string value or a `url`/`endpoint`/`uri` field.
    private static func url(in value: JSONValue) -> String? {
        if let s = value.stringValue, s.lowercased().hasPrefix("https://") { return s }
        if case .object(let o) = value {
            for key in ["url", "endpoint", "uri"] {
                if let s = o[key]?.stringValue, s.lowercased().hasPrefix("https://") { return s }
            }
        }
        return nil
    }
}
