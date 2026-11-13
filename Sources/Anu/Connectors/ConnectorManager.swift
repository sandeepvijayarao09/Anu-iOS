import Foundation
import Combine

/// Owns connector configuration and turns it into ready-to-register `Tool`s.
/// The orchestrator pulls `allConnectorTools` and installs them via
/// `ToolRegistry.replaceConnectorTools`. `@MainActor` so all mutation serializes
/// with the UI and the registry (no locks).
@MainActor
final class ConnectorManager: ObservableObject {
    static let shared = ConnectorManager()

    enum ConnectionStatus: Equatable {
        case idle
        case connecting
        case connected(toolCount: Int)
        case failed(String)
        /// OAuth server with no cached token — waiting for the user to tap Sign in.
        case needsSignIn
    }

    @Published private(set) var mcpServers: [MCPServerConfig]
    @Published private(set) var restConnectors: [RESTConnectorConfig]
    @Published private(set) var appConfig: AppLauncherConfig
    @Published private(set) var status: [UUID: ConnectionStatus] = [:]
    @Published private(set) var allConnectorTools: [any Tool] = []

    private let persists: Bool

    /// Designated init. `shared` loads from the Keychain; tests inject configs
    /// and set `persists: false` to avoid touching the Keychain.
    init(
        mcpServers: [MCPServerConfig]? = nil,
        restConnectors: [RESTConnectorConfig]? = nil,
        appConfig: AppLauncherConfig? = nil,
        persists: Bool = true
    ) {
        // Test isolation: launch with "-reset_connectors YES" to wipe stored
        // connectors (mirrors -reset_conversation).
        if persists, UserDefaults.standard.bool(forKey: "reset_connectors") {
            ConnectorStore.saveMCP([])
            ConnectorStore.saveREST([])
            ConnectorStore.saveApp(.default)
        }
        self.mcpServers = mcpServers ?? ConnectorStore.loadMCP()
        self.restConnectors = restConnectors ?? ConnectorStore.loadREST()
        self.appConfig = appConfig ?? ConnectorStore.loadApp()
        self.persists = persists
        if persists { sealStoredTokens() }
    }

    /// Saved connectors keep no tokens: any found inline (from earlier builds,
    /// or just typed in) move into the vault, bound to that server's host.
    /// Test managers (`persists: false`) keep theirs inline and never touch
    /// the real vault.
    private func sealStoredTokens() {
        let mcp = mcpServers.map { ConnectorSecrets.seal($0, in: .shared) }
        let rest = restConnectors.map { ConnectorSecrets.seal($0, in: .shared) }
        if mcp != mcpServers { mcpServers = mcp; ConnectorStore.saveMCP(mcp) }
        if rest != restConnectors { restConnectors = rest; ConnectorStore.saveREST(rest) }
    }

    /// Capability gate consulted by the agent loop before running `.external`
    /// tools. Connector tools are consented-by-configuration; app launching is
    /// behind a user toggle.
    func isEnabled(_ capability: ConnectorCapability) -> Bool {
        switch capability {
        case .connector: return true
        case .appLaunch: return appConfig.enabled
        }
    }

    // MARK: - Build tools

    /// Rebuilds `allConnectorTools`: REST + app-launch tools are synchronous;
    /// each enabled MCP server is connected and its tools discovered.
    func refresh() async {
        var tools: [any Tool] = []

        for connector in restConnectors where connector.enabled {
            tools.append(RESTConnectorTool(config: connector))
        }

        // App-launch tools are always registered; the capability gate (and the
        // per-scheme allowlist) decide whether a call is permitted — so a
        // disabled toggle yields a visible "blocked" message, not a missing tool.
        let opener = Self.makeOpener()
        tools.append(ShortcutsTool(appConfig: appConfig, opener: opener))
        tools.append(OpenAppTool(appConfig: appConfig, opener: opener))
        // One-step call/text/email: resolves a contact then opens tel:/sms:/mailto:.
        #if canImport(Contacts)
        tools.append(ContactActionTool(resolver: SystemContactResolver(), opener: opener, appConfig: appConfig))
        #endif
        // Phone controls (Android parity #16): an app by name, Maps directions, the share sheet.
        tools.append(OpenNamedAppTool(opener: opener))
        tools.append(NavigateTool(appConfig: appConfig, opener: opener))
        #if os(iOS)
        tools.append(ShareTool(presenter: SystemSharePresenter()))
        #endif

        #if canImport(MCP)
        // Decide which servers to connect. Defer OAuth servers with no cached
        // token so no sign-in sheet ever pops at launch — the user connects
        // them explicitly. Mark the rest connecting up front so the UI reflects
        // all of them at once.
        var connectable: [MCPServerConfig] = []
        for server in mcpServers where server.enabled {
            if case .oauth = server.auth, !MCPOAuthToken.exists(for: server.id) {
                status[server.id] = .needsSignIn
            } else {
                status[server.id] = .connecting
                connectable.append(server)
            }
        }

        // Connect to every server concurrently: each connect is bounded by its
        // own timeout, so one slow or dead server can no longer delay the others
        // (or stall an unrelated connector edit that triggers this refresh).
        // Errors are carried back as strings to keep the group result Sendable.
        let outcomes = await withTaskGroup(
            of: (MCPServerConfig, MCPConnection, [MCPToolInfo]?, String?).self
        ) { group in
            for server in connectable {
                group.addTask {
                    let connection = MCPConnection(config: server)
                    do {
                        return (server, connection, try await connection.connectAndList(), nil)
                    } catch {
                        return (server, connection, nil, error.localizedDescription)
                    }
                }
            }
            var collected: [(MCPServerConfig, MCPConnection, [MCPToolInfo]?, String?)] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        for (server, connection, infos, failure) in outcomes {
            if let infos {
                let host = URL(string: server.endpoint)?.host ?? server.endpoint
                for info in infos {
                    tools.append(MCPToolProxy(serverSlug: server.slug, serverHost: host, info: info, invoker: connection))
                }
                status[server.id] = .connected(toolCount: infos.count)
            } else {
                status[server.id] = .failed(failure ?? "Connection failed")
            }
        }
        #endif

        allConnectorTools = tools
    }

    /// Interactive OAuth connect for one server — the ONLY place the browser
    /// sign-in sheet is allowed to appear (in direct response to a tap). Obtains
    /// and stores the token; the caller then re-runs `refresh()` to register the
    /// now-reachable server's tools.
    func signIn(serverID: UUID) async {
        guard let server = mcpServers.first(where: { $0.id == serverID }) else { return }
        status[serverID] = .connecting
        #if canImport(MCP)
        do {
            let connection = MCPConnection(config: server)
            let infos = try await connection.connectAndList(interactive: true)
            status[serverID] = .connected(toolCount: infos.count)
        } catch {
            status[serverID] = .failed(error.localizedDescription)
        }
        #else
        status[serverID] = .failed("MCP is not available in this build")
        #endif
    }

    /// Forgets a server's OAuth token; the caller re-runs `refresh()` to drop its
    /// tools from the registry.
    func signOut(serverID: UUID) {
        MCPOAuthToken.clear(for: serverID)
        status[serverID] = .needsSignIn
    }

    private static func makeOpener() -> any URLOpening {
        #if canImport(UIKit)
        return SystemURLOpener()
        #else
        return NoopURLOpener()
        #endif
    }

    // MARK: - CRUD (used by ConnectorsView)

    func addMCPServer(_ server: MCPServerConfig) { mcpServers.append(server); persistMCP() }
    func updateMCPServer(_ server: MCPServerConfig) {
        if let i = mcpServers.firstIndex(where: { $0.id == server.id }) { mcpServers[i] = server }
        persistMCP()
    }
    func removeMCPServer(id: UUID) {
        mcpServers.removeAll { $0.id == id }
        if persists { Vault.shared.delete(ConnectorSecrets.ref(mcp: id)) }
        status[id] = nil
        MCPOAuthToken.clear(for: id)   // forget any stored OAuth token
        persistMCP()
    }

    func addRESTConnector(_ connector: RESTConnectorConfig) { restConnectors.append(connector); persistREST() }
    func updateRESTConnector(_ connector: RESTConnectorConfig) {
        if let i = restConnectors.firstIndex(where: { $0.id == connector.id }) { restConnectors[i] = connector }
        persistREST()
    }
    func removeRESTConnector(id: UUID) {
        restConnectors.removeAll { $0.id == id }
        if persists { Vault.shared.delete(ConnectorSecrets.ref(rest: id)) }
        persistREST()
    }

    func setAppConfig(_ config: AppLauncherConfig) {
        appConfig = config
        if persists { ConnectorStore.saveApp(config) }
    }

    private func persistMCP() { if persists { sealStoredTokens(); ConnectorStore.saveMCP(mcpServers) } }
    private func persistREST() { if persists { sealStoredTokens(); ConnectorStore.saveREST(restConnectors) } }
}

/// Fallback opener for platforms without UIKit (also keeps non-iOS builds compiling).
struct NoopURLOpener: URLOpening {
    func open(_ url: URL) async -> Bool { false }
}
