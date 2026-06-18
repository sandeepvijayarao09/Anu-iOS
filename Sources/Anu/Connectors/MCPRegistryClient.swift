import Foundation

/// A server discovered in the official MCP Registry that has a remote
/// streamable-http endpoint we can actually connect to.
struct RegistryServer: Sendable, Identifiable, Equatable {
    var id: String { endpoint }
    let name: String
    let title: String
    let description: String
    let endpoint: String
}

/// Reads the official MCP Registry (`registry.modelcontextprotocol.io`). Plain
/// URLSession + Codable, MCP-free, injectable session — fully unit-testable.
final class MCPRegistryClient: Sendable {
    private let session: URLSession
    private let base = "https://registry.modelcontextprotocol.io/v0/servers"

    init(session: URLSession = .shared) { self.session = session }

    /// One page: servers that expose a streamable-http remote, plus the cursor.
    func fetch(cursor: String? = nil, limit: Int = 50) async throws -> (servers: [RegistryServer], nextCursor: String?) {
        guard var comps = URLComponents(string: base) else { throw URLError(.badURL) }
        comps.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty {
            comps.queryItems?.append(URLQueryItem(name: "cursor", value: cursor))
        }
        guard let url = comps.url else { throw URLError(.badURL) }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(RegistryResponse.self, from: data)
        let servers = decoded.servers.compactMap { entry -> RegistryServer? in
            let s = entry.server
            // Require HTTPS: registry entries are third-party data, so never
            // wire the agent to a cleartext (http://) endpoint.
            guard let remote = s.remotes?.first(where: {
                      $0.type == "streamable-http"
                      && ($0.url ?? "").lowercased().hasPrefix("https://")
                  }), let endpoint = remote.url else { return nil }
            return RegistryServer(name: s.name, title: s.title ?? s.name,
                                  description: s.description ?? "", endpoint: endpoint)
        }
        return (servers, decoded.metadata?.nextCursor)
    }

    /// Client-side search across a bounded number of pages (the API has no text
    /// filter), de-duplicated by endpoint.
    func search(_ query: String, maxPages: Int = 4) async throws -> [RegistryServer] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        var seen = Set<String>()
        var results: [RegistryServer] = []
        var cursor: String? = nil
        for _ in 0..<maxPages {
            let (servers, next) = try await fetch(cursor: cursor)
            for server in servers where !seen.contains(server.endpoint) {
                let match = q.isEmpty
                    || server.name.lowercased().contains(q)
                    || server.title.lowercased().contains(q)
                    || server.description.lowercased().contains(q)
                if match { seen.insert(server.endpoint); results.append(server) }
            }
            guard let next, !next.isEmpty else { break }
            cursor = next
        }
        return results
    }
}

// MARK: - Decode shapes (the registry nests `server` inside each entry)

private struct RegistryResponse: Decodable {
    let servers: [Entry]
    let metadata: Meta?

    struct Entry: Decodable { let server: ServerInfo }
    struct ServerInfo: Decodable {
        let name: String
        let title: String?
        let description: String?
        let remotes: [Remote]?
    }
    struct Remote: Decodable { let type: String; let url: String? }
    struct Meta: Decodable { let nextCursor: String? }
}
