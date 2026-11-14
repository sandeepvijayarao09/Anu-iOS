import Foundation

/// Moves connector credentials (MCP bearer tokens, REST auth headers) out of
/// the connector configs and into the vault, each bound to its own server's
/// host and usable only by connectors (Android ADR-046: "MCP server tokens,
/// each bound to its server's host"). Saved configs keep no token; requests
/// get it from `Vault.authorize` at send time.
enum ConnectorSecrets {
    static func ref(mcp id: UUID) -> SecretRef { SecretRef("mcp.\(id.uuidString)") }
    static func ref(rest id: UUID) -> SecretRef { SecretRef("rest.\(id.uuidString)") }

    /// Returns `server` with any inline bearer token moved into `vault`.
    static func seal(_ server: MCPServerConfig, in vault: Vault) -> MCPServerConfig {
        guard case .bearer(let token) = server.auth, !token.isEmpty,
              let host = URL(string: server.endpoint)?.host?.lowercased() else { return server }
        do {
            try vault.store(token, ref: ref(mcp: server.id), kind: .apiKey,
                            label: "\(server.name) token", service: server.name,
                            boundHosts: [host], allowedUsers: [VaultCaller.connectors])
        } catch { return server }   // keep it working rather than lose the token
        var sealed = server
        sealed.auth = .bearer("")
        return sealed
    }

    /// Returns `connector` with any inline auth header value moved into `vault`.
    static func seal(_ connector: RESTConnectorConfig, in vault: Vault) -> RESTConnectorConfig {
        guard let value = connector.authHeaderValue, !value.isEmpty,
              let name = connector.authHeaderName, !name.isEmpty,
              let host = URL(string: connector.baseURL)?.host?.lowercased() else { return connector }
        do {
            try vault.store(value, ref: ref(rest: connector.id), kind: .apiKey,
                            label: "\(connector.name) key", service: connector.name,
                            boundHosts: [host], allowedUsers: [VaultCaller.connectors])
        } catch { return connector }
        var sealed = connector
        sealed.authHeaderValue = nil
        return sealed
    }

    /// Attaches a sealed MCP token, if the vault holds one for this server.
    /// Refusals (wrong host, plain HTTP) send the request without it.
    static func authorizeMCP(_ request: URLRequest, serverID: UUID, vault: Vault = .shared) -> URLRequest {
        let ref = ref(mcp: serverID)
        guard vault.contains(ref) else { return request }
        return (try? vault.authorize(request, use: SecretUse(
            ref: ref, header: "Authorization", caller: VaultCaller.connectors, scheme: "Bearer"))) ?? request
    }

    /// Attaches a sealed REST header. Throws if the vault refuses, so a
    /// connector never silently calls its API unauthenticated.
    static func authorizeREST(_ request: URLRequest, connector: RESTConnectorConfig, vault: Vault = .shared) throws -> URLRequest {
        let ref = ref(rest: connector.id)
        guard let name = connector.authHeaderName, !name.isEmpty, vault.contains(ref) else { return request }
        return try vault.authorize(request, use: SecretUse(ref: ref, header: name, caller: VaultCaller.connectors))
    }
}
