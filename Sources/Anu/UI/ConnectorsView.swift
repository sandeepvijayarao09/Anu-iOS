import SwiftUI

/// Manage external connectors: MCP servers, REST APIs, and device/app launching.
/// Edits flow through `ConnectorManager` and re-run discovery via the orchestrator.
struct ConnectorsView: View {
    @ObservedObject private var manager = ConnectorManager.shared
    @State private var showAddMCP = false
    @State private var showAddREST = false

    var body: some View {
        Form {
            // MARK: Device & apps
            Section {
                Toggle("Let the agent open apps & run Shortcuts", isOn: appEnabledBinding)
                    .accessibilityIdentifier("appLaunchToggle")
                if manager.appConfig.enabled {
                    NavigationLink {
                        SchemeAllowlistView()
                    } label: {
                        LabeledContent("Allowed URL schemes", value: "\(manager.appConfig.allowedSchemes.count)")
                    }
                }
            } header: {
                Text("Device & Apps")
            } footer: {
                Text("Lets the agent run your Apple Shortcuts and open other apps (Maps, Mail, web links…). Every launch is shown in the chat, and only the allowed URL schemes are permitted.")
            }

            // MARK: MCP servers
            Section {
                if manager.mcpServers.isEmpty {
                    Text("No MCP servers yet.").foregroundStyle(.secondary)
                }
                ForEach(manager.mcpServers) { server in
                    MCPServerRow(
                        server: server,
                        status: manager.status[server.id],
                        onSignIn: { Task { await AgentOrchestrator.shared.signInConnector(serverID: server.id) } },
                        onSignOut: { Task { await AgentOrchestrator.shared.signOutConnector(serverID: server.id) } }
                    )
                }
                .onDelete { offsets in
                    offsets.map { manager.mcpServers[$0].id }.forEach(manager.removeMCPServer(id:))
                    reload()
                }
                Button { showAddMCP = true } label: { Label("Add MCP Server", systemImage: "plus") }
                    .accessibilityIdentifier("addMCPServer")
                NavigationLink {
                    MCPCatalogView()
                } label: {
                    Label("Add from Catalog", systemImage: "square.grid.2x2")
                }
                .accessibilityIdentifier("addFromCatalog")
                NavigationLink {
                    RegistryBrowseView()
                } label: {
                    Label("Browse Registry", systemImage: "magnifyingglass")
                }
                .accessibilityIdentifier("browseRegistry")
                NavigationLink {
                    UCPMerchantView()
                } label: {
                    Label("Add Shopping Merchant (UCP)", systemImage: "cart")
                }
                .accessibilityIdentifier("addUCPMerchant")
            } header: {
                Text("MCP Servers")
            } footer: {
                Text("Connect to remote Model Context Protocol servers over HTTPS. Their tools are discovered automatically and made available to the agent (named mcp__server__tool).")
            }

            // MARK: REST connectors
            Section {
                if manager.restConnectors.isEmpty {
                    Text("No REST connectors yet.").foregroundStyle(.secondary)
                }
                ForEach(manager.restConnectors) { connector in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connector.name)
                        Text("\(connector.method) \(connector.baseURL)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .onDelete { offsets in
                    offsets.map { manager.restConnectors[$0].id }.forEach(manager.removeRESTConnector(id:))
                    reload()
                }
                Button {
                    showAddREST = true
                } label: {
                    Label("Add REST Connector", systemImage: "plus")
                }
                .accessibilityIdentifier("addRESTConnector")
            } header: {
                Text("REST APIs")
            } footer: {
                Text("Expose any HTTP API as a tool. The agent can set a path, query, and (for write methods) a JSON body, but can only reach the host you configure.")
            }
        }
        .navigationTitle("Connectors")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { EditButton() }
        .sheet(isPresented: $showAddMCP) {
            AddMCPServerView { manager.addMCPServer($0); reload() }
        }
        .sheet(isPresented: $showAddREST) {
            AddRESTConnectorView { manager.addRESTConnector($0); reload() }
        }
        .task { reload() }
    }

    private var appEnabledBinding: Binding<Bool> {
        Binding(
            get: { manager.appConfig.enabled },
            set: { newValue in
                var config = manager.appConfig
                config.enabled = newValue
                manager.setAppConfig(config)
                reload()
            }
        )
    }

    private func reload() {
        Task { await AgentOrchestrator.shared.reloadConnectors() }
    }
}

