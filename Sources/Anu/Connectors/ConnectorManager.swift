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

        #if canImport(MCP)
        for server in mcpServers where server.enabled {
            // Defer OAuth servers with no cached token so no sign-in sheet ever
            // pops at launch — the user connects them explicitly.
            if case .oauth = server.auth, !MCPOAuthToken.exists(for: server.id) {
                status[server.id] = .needsSignIn
                continue
            }
            status[server.id] = .connecting
            do {
                let connection = MCPConnection(config: server)
                let infos = try await connection.connectAndList()
                let host = URL(string: server.endpoint)?.host ?? server.endpoint
                for info in infos {
                    tools.append(MCPToolProxy(serverSlug: server.slug, serverHost: host, info: info, invoker: connection))
                }
                status[server.id] = .connected(toolCount: infos.count)
            } catch {
                status[server.id] = .failed(error.localizedDescription)
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
        persistREST()
    }

    func setAppConfig(_ config: AppLauncherConfig) {
        appConfig = config
        if persists { ConnectorStore.saveApp(config) }
    }

    private func persistMCP() { if persists { ConnectorStore.saveMCP(mcpServers) } }
    private func persistREST() { if persists { ConnectorStore.saveREST(restConnectors) } }
}

/// Fallback opener for platforms without UIKit (also keeps non-iOS builds compiling).
struct NoopURLOpener: URLOpening {
    func open(_ url: URL) async -> Bool { false }
}
