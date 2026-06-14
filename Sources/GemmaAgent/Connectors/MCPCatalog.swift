import Foundation

/// A one-tap, ready-to-add MCP server. Every endpoint here was verified live
/// (a no-auth server answers `initialize`; an OAuth one returns 401) — no
/// fabricated URLs. OAuth entries are added in `.needsSignIn` until the user
/// taps Sign in.
struct MCPCatalogEntry: Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    let description: String
    let endpoint: String
    let auth: MCPAuth
    let category: String

    func makeConfig() -> MCPServerConfig {
        MCPServerConfig(name: name, endpoint: endpoint, auth: auth)
    }
}

enum MCPCatalog {
    static let entries: [MCPCatalogEntry] = [
        // Works instantly — no account needed.
        .init(name: "DeepWiki",
              description: "Ask questions about any public GitHub repo's docs and code.",
              endpoint: "https://mcp.deepwiki.com/mcp", auth: .none, category: "Docs & Code"),

        // OAuth — tap Sign in after adding.
        .init(name: "GitHub",
              description: "Repositories, issues, pull requests, and code search.",
              endpoint: "https://api.githubcopilot.com/mcp/", auth: .oauth, category: "Developer"),
        .init(name: "Linear",
              description: "Find, create, and update Linear issues and projects.",
              endpoint: "https://mcp.linear.app/mcp", auth: .oauth, category: "Productivity"),
        .init(name: "Notion",
              description: "Search and edit your Notion pages and databases.",
              endpoint: "https://mcp.notion.com/mcp", auth: .oauth, category: "Productivity"),
        .init(name: "Sentry",
              description: "Query errors and issues, and pull live context into the agent.",
              endpoint: "https://mcp.sentry.dev/mcp", auth: .oauth, category: "Developer"),
        .init(name: "Stripe",
              description: "Interact with the Stripe API and knowledge base.",
              endpoint: "https://mcp.stripe.com", auth: .oauth, category: "Commerce"),
        .init(name: "Semgrep",
              description: "Static analysis and security scanning.",
              endpoint: "https://mcp.semgrep.ai/mcp", auth: .oauth, category: "Docs & Code"),
    ]

    /// Catalog entries grouped by category, in stable display order.
    static var byCategory: [(category: String, entries: [MCPCatalogEntry])] {
        let order = ["Docs & Code", "Developer", "Productivity", "Commerce"]
        let grouped = Dictionary(grouping: entries, by: \.category)
        return order.compactMap { cat in
            grouped[cat].map { (cat, $0) }
        }
    }
}
