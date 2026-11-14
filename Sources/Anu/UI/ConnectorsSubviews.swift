import SwiftUI

// MARK: - Rows & status

struct MCPServerRow: View {
    let server: MCPServerConfig
    let status: ConnectorManager.ConnectionStatus?
    var onSignIn: () -> Void
    var onSignOut: () -> Void

    private var isOAuth: Bool { if case .oauth = server.auth { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(server.name)
            Text(server.endpoint).font(.anuLabel).foregroundStyle(.secondary).lineLimit(1)
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
                .font(.anuLabel).buttonStyle(.borderless)
                .accessibilityIdentifier("mcpSignOut")
        case .connecting:
            EmptyView()
        default: // needsSignIn / failed / idle / nil
            Button("Sign in", action: onSignIn)
                .font(.anuLabel).buttonStyle(.borderedProminent).controlSize(.small)
                .accessibilityIdentifier("mcpSignIn")
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch status {
        case .connecting:
            Label("Connecting…", systemImage: "ellipsis.circle").font(.anuLabel).foregroundStyle(.secondary)
        case .connected(let count):
            Label("\(count) tool\(count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                .font(.anuLabel).foregroundStyle(.green)
        case .needsSignIn:
            Label("Sign in required", systemImage: "lock").font(.anuLabel).foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.anuLabel).foregroundStyle(.red).lineLimit(2)
        case .idle, .none:
            EmptyView()
        }
    }
}

// MARK: - Add MCP server sheet

struct AddMCPServerView: View {
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
                        .anuURLField()
                        .accessibilityIdentifier("mcpEndpointField")
                }
                Section("Authentication") {
                    Picker("Auth", selection: $authKind) {
                        ForEach(AuthKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if authKind == .token {
                        SecureField("Bearer token", text: $token)
                            .anuNoAutocorrect()
                    } else if authKind == .oauth {
                        Text("You'll sign in via your browser after adding the server.")
                            .font(.anuLabel).foregroundStyle(.secondary)
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

struct AddRESTConnectorView: View {
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
                        .anuURLField()
                    Picker("Method", selection: $method) {
                        ForEach(methods, id: \.self) { Text($0) }
                    }
                }
                Section("Auth header (optional)") {
                    TextField("Header name (e.g. Authorization)", text: $headerName)
                        .anuNoAutocorrect()
                    SecureField("Header value (e.g. Bearer …)", text: $headerValue)
                        .anuNoAutocorrect()
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

struct SchemeAllowlistView: View {
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
                        .anuNoAutocorrect()
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

struct MCPCatalogView: View {
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
                                VStack(alignment: .leading, spacing: Space.xs) {
                                    HStack(spacing: Space.tight) {
                                        Text(entry.name)
                                        authBadge(entry.auth)
                                    }
                                    Text(entry.description).font(.anuLabel).foregroundStyle(.secondary)
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
        case .none: Text("No auth").font(.anuLabel).foregroundStyle(.green)
        case .bearer: Text("Token").font(.anuLabel).foregroundStyle(.orange)
        case .oauth: Text("OAuth").font(.anuLabel).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Registry browse

struct RegistryBrowseView: View {
    @ObservedObject private var manager = ConnectorManager.shared
    @State private var query = ""
    @State private var results: [RegistryServer] = []
    @State private var loading = false
    @State private var error: String?
    private let client = MCPRegistryClient()

    var body: some View {
        List {
            if loading { HStack { ProgressView(); Text("Searching the registry…") } }
            if let error { Text(error).font(.anuLabel).foregroundStyle(.red) }
            ForEach(results) { server in
                Button {
                    // Registry carries no auth hint; add as no-auth and let open
                    // servers connect. OAuth-gated ones show an error to re-add.
                    manager.addMCPServer(MCPServerConfig(name: server.title, endpoint: server.endpoint, auth: .none))
                    Task { await AgentOrchestrator.shared.reloadConnectors() }
                } label: {
                    VStack(alignment: .leading, spacing: Space.hair) {
                        Text(server.title)
                        Text(server.endpoint).font(.anuLabel).foregroundStyle(.secondary).lineLimit(1)
                        if !server.description.isEmpty {
                            Text(server.description).font(.anuLabel).foregroundStyle(.secondary).lineLimit(2)
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

struct UCPMerchantView: View {
    @ObservedObject private var manager = ConnectorManager.shared
    @State private var domain = ""
    @State private var status: String?
    @State private var working = false
    private let ucp = UCPDiscovery()

    var body: some View {
        Form {
            Section {
                TextField("Store domain (e.g. gymshark.com)", text: $domain)
                    .anuURLField()
                Button {
                    Task { await discover() }
                } label: {
                    HStack { if working { ProgressView().padding(.trailing, Space.xs) }; Text("Discover") }
                }
                .disabled(domain.trimmingCharacters(in: .whitespaces).isEmpty || working)
            } footer: {
                Text("Finds the store's Universal Commerce Protocol endpoint — or its Shopify Agentic Storefront — and adds its shopping tools: product search, product details, cart, and store policies. Works with most Shopify stores. Checkout and payment aren't included.")
            }
            if let status {
                Text(status).font(.anuLabel)
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
                if case .oauth = config.auth {
                    status = "Added \(config.name). Tap Sign in on the MCP Servers list to connect."
                } else {
                    status = "Added \(config.name) — its shopping tools are now available in chat."
                }
            } else {
                status = "No agentic-commerce endpoint found for that store."
            }
        } catch {
            status = "Couldn't reach that store."
        }
    }
}

// MARK: - Add Connector hub

/// Dedicated destination for adding a connector, gathering every entry point in
/// one place: browse the curated catalog or the official registry, connect a
/// shopping merchant, or add an MCP/REST endpoint by hand. Managing already-added
/// connectors stays in `ConnectorsView`.
struct AddConnectorView: View {
    @ObservedObject private var manager = ConnectorManager.shared
    @State private var showAddMCP = false
    @State private var showAddREST = false

    var body: some View {
        List {
            Section {
                NavigationLink { MCPCatalogView() } label: {
                    AddConnectorRow(title: "Catalog",
                                    subtitle: "Curated, ready-to-use servers — DeepWiki, GitHub, Notion, and more.",
                                    systemImage: "square.grid.2x2.fill", tint: .secondary)
                }
                .accessibilityIdentifier("addFromCatalog")
                NavigationLink { RegistryBrowseView() } label: {
                    AddConnectorRow(title: "Browse Registry",
                                    subtitle: "Search the official Model Context Protocol registry.",
                                    systemImage: "magnifyingglass", tint: .purple)
                }
                .accessibilityIdentifier("browseRegistry")
            } header: {
                Text("Discover")
            } footer: {
                Text("MCP servers expose their tools to the agent automatically. Every call is shown in the chat, and OAuth servers ask you to sign in first.")
            }

            Section {
                NavigationLink { UCPMerchantView() } label: {
                    AddConnectorRow(title: "Shopping Merchant",
                                    subtitle: "Add a store's product-search tools via its UCP endpoint.",
                                    systemImage: "cart.fill", tint: .green)
                }
                .accessibilityIdentifier("addUCPMerchant")
            } header: {
                Text("Shopping")
            }

            Section {
                Button { showAddMCP = true } label: {
                    AddConnectorRow(title: "MCP Server",
                                    subtitle: "Connect any HTTPS MCP endpoint (no auth, token, or OAuth).",
                                    systemImage: "server.rack", tint: .indigo)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("addMCPServer")
                Button { showAddREST = true } label: {
                    AddConnectorRow(title: "REST API",
                                    subtitle: "Expose any HTTP API to the agent as a single tool.",
                                    systemImage: "network", tint: .orange)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("addRESTConnector")
            } header: {
                Text("Custom")
            } footer: {
                Text("Point the agent at your own endpoints. The host is fixed by what you enter, so the agent can't redirect elsewhere.")
            }
        }
        .navigationTitle("Add a Connector")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showAddMCP) {
            AddMCPServerView { manager.addMCPServer($0); reload() }
        }
        .sheet(isPresented: $showAddREST) {
            AddRESTConnectorView { manager.addRESTConnector($0); reload() }
        }
    }

    private func reload() {
        Task { await AgentOrchestrator.shared.reloadConnectors() }
    }
}

/// A titled, icon-led row used across the Add Connector hub.
private struct AddConnectorRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: Space.base) {
            Image(systemName: systemImage)
                .font(.anuHeading)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle).font(.anuLabel).foregroundStyle(.secondary)
            }
        }
    }
}
