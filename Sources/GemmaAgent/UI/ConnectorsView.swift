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

// MARK: - Rows & status

private struct MCPServerRow: View {
    let server: MCPServerConfig
    let status: ConnectorManager.ConnectionStatus?
    var onSignIn: () -> Void
    var onSignOut: () -> Void

    private var isOAuth: Bool { if case .oauth = server.auth { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(server.name)
            Text(server.endpoint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                statusLabel
                Spacer()
                if isOAuth { authButton }
            }
        }
    }

    @ViewBuilder private var authButton: some View {
        switch status {
        case .connected:
            Button("Sign out", action: onSignOut)
                .font(.caption2).buttonStyle(.borderless)
                .accessibilityIdentifier("mcpSignOut")
        case .connecting:
            EmptyView()
        default: // needsSignIn / failed / idle / nil
            Button("Sign in", action: onSignIn)
                .font(.caption2).buttonStyle(.borderedProminent).controlSize(.small)
                .accessibilityIdentifier("mcpSignIn")
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch status {
        case .connecting:
            Label("Connecting…", systemImage: "ellipsis.circle").font(.caption2).foregroundStyle(.secondary)
        case .connected(let count):
            Label("\(count) tool\(count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)
        case .needsSignIn:
            Label("Sign in required", systemImage: "lock").font(.caption2).foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.red).lineLimit(2)
        case .idle, .none:
            EmptyView()
        }
    }
}

// MARK: - Add MCP server sheet

private struct AddMCPServerView: View {
    var onAdd: (MCPServerConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var endpoint = ""
    @State private var authKind = AuthKind.none
    @State private var token = ""

    private enum AuthKind: String, CaseIterable, Identifiable {
        case none = "None", token = "Token", oauth = "OAuth"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("mcpNameField")
                    TextField("HTTPS endpoint", text: $endpoint)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .accessibilityIdentifier("mcpEndpointField")
                }
                Section("Authentication") {
                    Picker("Auth", selection: $authKind) {
                        ForEach(AuthKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if authKind == .token {
                        SecureField("Bearer token", text: $token)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    } else if authKind == .oauth {
                        Text("You'll sign in via your browser after adding the server.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Add MCP Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let auth: MCPAuth
                        switch authKind {
                        case .none: auth = .none
                        case .token: auth = .bearer(token)
                        case .oauth: auth = .oauth
                        }
                        onAdd(MCPServerConfig(
                            name: name.isEmpty ? endpoint : name,
                            endpoint: endpoint.trimmingCharacters(in: .whitespaces),
                            auth: auth
                        ))
                        dismiss()
                    }
                    .disabled(endpoint.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Add REST connector sheet

private struct AddRESTConnectorView: View {
    var onAdd: (RESTConnectorConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var baseURL = ""
    @State private var method = "GET"
    @State private var headerName = ""
    @State private var headerValue = ""
    @State private var toolDescription = ""

    private let methods = ["GET", "POST", "PUT", "PATCH", "DELETE"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Base URL", text: $baseURL)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Picker("Method", selection: $method) {
                        ForEach(methods, id: \.self) { Text($0) }
                    }
                }
                Section("Auth header (optional)") {
                    TextField("Header name (e.g. Authorization)", text: $headerName)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    SecureField("Header value (e.g. Bearer …)", text: $headerValue)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                Section("What it does (shown to the agent)") {
                    TextField("Description", text: $toolDescription, axis: .vertical)
                }
            }
            .navigationTitle("Add REST Connector")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(RESTConnectorConfig(
                            name: name.isEmpty ? baseURL : name,
                            baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                            method: method,
                            authHeaderName: headerName.isEmpty ? nil : headerName,
                            authHeaderValue: headerValue.isEmpty ? nil : headerValue,
                            toolDescription: toolDescription
                        ))
                        dismiss()
                    }
                    .disabled(baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Scheme allowlist editor

private struct SchemeAllowlistView: View {
    @ObservedObject private var manager = ConnectorManager.shared
    @State private var newScheme = ""

    var body: some View {
        Form {
            Section {
                ForEach(manager.appConfig.allowedSchemes, id: \.self) { scheme in
                    Text(scheme)
                }
                .onDelete { offsets in
                    var config = manager.appConfig
                    config.allowedSchemes.remove(atOffsets: offsets)
                    manager.setAppConfig(config)
                }
            } footer: {
                Text("Only these URL schemes may be opened by the agent.")
            }
            Section {
                HStack {
                    TextField("Add scheme (e.g. spotify)", text: $newScheme)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("Add") {
                        let scheme = newScheme.lowercased().trimmingCharacters(in: .whitespaces)
                        guard !scheme.isEmpty, !manager.appConfig.allowedSchemes.contains(scheme) else { return }
                        var config = manager.appConfig
                        config.allowedSchemes.append(scheme)
                        manager.setAppConfig(config)
                        newScheme = ""
                    }
                    .disabled(newScheme.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationTitle("Allowed Schemes")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Catalog

private struct MCPCatalogView: View {
    @ObservedObject private var manager = ConnectorManager.shared

    var body: some View {
        List {
            ForEach(MCPCatalog.byCategory, id: \.category) { group in
                Section(group.category) {
                    ForEach(group.entries) { entry in
                        Button {
                            manager.addMCPServer(entry.makeConfig())
                            Task { await AgentOrchestrator.shared.reloadConnectors() }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(entry.name)
                                        authBadge(entry.auth)
                                    }
                                    Text(entry.description).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: isAdded(entry) ? "checkmark.circle.fill" : "plus.circle")
                                    .foregroundStyle(isAdded(entry) ? .green : .accentColor)
                            }
                        }
                        .disabled(isAdded(entry))
                    }
                }
            }
        }
        .navigationTitle("Catalog")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func isAdded(_ entry: MCPCatalogEntry) -> Bool {
        manager.mcpServers.contains { $0.endpoint == entry.endpoint }
    }

    @ViewBuilder private func authBadge(_ auth: MCPAuth) -> some View {
        switch auth {
        case .none: Text("No auth").font(.caption2).foregroundStyle(.green)
        case .bearer: Text("Token").font(.caption2).foregroundStyle(.orange)
        case .oauth: Text("OAuth").font(.caption2).foregroundStyle(.blue)
        }
    }
}

// MARK: - Registry browse

private struct RegistryBrowseView: View {
    @ObservedObject private var manager = ConnectorManager.shared
    @State private var query = ""
    @State private var results: [RegistryServer] = []
    @State private var loading = false
    @State private var error: String?
    private let client = MCPRegistryClient()

    var body: some View {
        List {
            if loading { HStack { ProgressView(); Text("Searching the registry…") } }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            ForEach(results) { server in
                Button {
                    // Registry carries no auth hint; add as no-auth and let open
                    // servers connect. OAuth-gated ones show an error to re-add.
                    manager.addMCPServer(MCPServerConfig(name: server.title, endpoint: server.endpoint, auth: .none))
                    Task { await AgentOrchestrator.shared.reloadConnectors() }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.title)
                        Text(server.endpoint).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        if !server.description.isEmpty {
                            Text(server.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search MCP servers")
        .onSubmit(of: .search) { Task { await runSearch() } }
        .navigationTitle("Registry")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await runSearch() }
    }

    private func runSearch() async {
        loading = true
        self.error = nil
        do { results = try await client.search(query) }
        catch { self.error = "Couldn't load the registry." }
        loading = false
    }
}

// MARK: - UCP shopping merchant

private struct UCPMerchantView: View {
    @ObservedObject private var manager = ConnectorManager.shared
    @State private var domain = ""
    @State private var status: String?
    @State private var working = false
    private let ucp = UCPDiscovery()

    var body: some View {
        Form {
            Section {
                TextField("Merchant domain (e.g. shop.example.com)", text: $domain)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
                Button {
                    Task { await discover() }
                } label: {
                    HStack { if working { ProgressView().padding(.trailing, 4) }; Text("Discover") }
                }
                .disabled(domain.trimmingCharacters(in: .whitespaces).isEmpty || working)
            } footer: {
                Text("Looks up the merchant's /.well-known/ucp and adds its MCP product-search tools. Checkout/payments are not included.")
            }
            if let status {
                Text(status).font(.caption)
                    .foregroundStyle(status.hasPrefix("Added") ? .green : .secondary)
            }
        }
        .navigationTitle("Shopping Merchant")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func discover() async {
        working = true; status = nil
        defer { working = false }
        do {
            if let config = try await ucp.discover(merchantDomain: domain) {
                manager.addMCPServer(config)
                await AgentOrchestrator.shared.reloadConnectors()
                status = "Added \(config.name). Sign in from the MCP Servers list if prompted."
            } else {
                status = "No MCP binding found at that merchant's /.well-known/ucp."
            }
        } catch {
            status = "Couldn't reach that merchant."
        }
    }
}
