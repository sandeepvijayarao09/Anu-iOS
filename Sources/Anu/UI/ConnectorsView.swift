import SwiftUI

/// Manage external connectors: MCP servers, REST APIs, and device/app launching.
/// Adding a new connector lives in the dedicated `AddConnectorView` hub; this
/// screen lists and manages what's already connected. Edits flow through
/// `ConnectorManager` and re-run discovery via the orchestrator.
struct ConnectorsView: View {
    @ObservedObject private var manager = ConnectorManager.shared

    var body: some View {
        Form {
            // MARK: Add a connector — dedicated hub for every add flow
            Section {
                NavigationLink {
                    AddConnectorView()
                } label: {
                    Label("Add a Connector", systemImage: "plus.circle.fill")
                }
                .accessibilityIdentifier("addConnector")
            } footer: {
                Text("Browse the catalog or the registry, add a shopping merchant, or connect your own MCP server or REST API.")
            }

            // MARK: Gmail (Android parity #10)
            Section {
                NavigationLink {
                    GmailSettingsView()
                } label: {
                    Label("Gmail", systemImage: "envelope")
                }
                .accessibilityIdentifier("gmailConnector")
            } footer: {
                Text("Search, read, draft and send email with your approval.")
            }

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

            // MARK: Agents on the user's network (A2A, ADR-105)
            Section {
                NavigationLink {
                    A2AAgentsView()
                } label: {
                    Label("Agents on your network", systemImage: "person.2.wave.2")
                }
                .accessibilityIdentifier("a2aAgentsRow")
            } footer: {
                Text("Agents on your own network (Agent2Agent protocol). Each message to one asks you first.")
            }

            // MARK: MCP servers (management — add lives in the hub)
            Section {
                if manager.mcpServers.isEmpty {
                    Text("No MCP servers yet — tap “Add a Connector” above.")
                        .foregroundStyle(.secondary)
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
            } header: {
                Text("MCP Servers")
            } footer: {
                Text("Remote Model Context Protocol servers connected over HTTPS. Their tools are discovered automatically and made available to the agent (named mcp__server__tool).")
            }

            // MARK: REST connectors (management — add lives in the hub)
            Section {
                if manager.restConnectors.isEmpty {
                    Text("No REST connectors yet — tap “Add a Connector” above.")
                        .foregroundStyle(.secondary)
                }
                ForEach(manager.restConnectors) { connector in
                    VStack(alignment: .leading, spacing: Space.hair) {
                        Text(connector.name)
                        Text("\(connector.method) \(connector.baseURL)")
                            .font(.anuLabel).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .onDelete { offsets in
                    offsets.map { manager.restConnectors[$0].id }.forEach(manager.removeRESTConnector(id:))
                    reload()
                }
            } header: {
                Text("REST APIs")
            } footer: {
                Text("Any HTTP API exposed to the agent as a tool. The agent can set a path, query, and (for write methods) a JSON body, but can only reach the host you configure.")
            }
        }
        .navigationTitle("Connectors")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
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
