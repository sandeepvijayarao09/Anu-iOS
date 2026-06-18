import SwiftUI

/// Configure the private compute server escalation. PCC-*inspired*, not Apple
/// PCC — the honest framing (operator-trusted, not cryptographically verifiable)
/// is stated plainly in the footer.
struct PrivateCloudView: View {
    @State private var endpoint = KeychainStore.shared.string(forKey: "pcs_endpoint") ?? ""
    @State private var devToken = KeychainStore.shared.string(forKey: DeviceAttestation.devTokenKey) ?? ""
    @AppStorage(CloudProvider.preferenceKey) private var providerRaw = "auto"
    @State private var showDevToken = false
    @State private var testResult = ""
    @State private var isTesting = false

    private let attestation: any DeviceAttesting = DeviceAttestation.shared

    var body: some View {
        Form {
            Section {
                TextField("https://your-server.example/api", text: $endpoint)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #if os(iOS)
                    .keyboardType(.URL)
                    #endif
                    .accessibilityIdentifier("pcsEndpointField")
                if !endpoint.isEmpty && !isHTTPS {
                    Label("Must be an https:// URL", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Server endpoint")
            } footer: {
                Text("Your private compute server's base URL. HTTPS only. The app calls /v1/generate on this host and nowhere else.")
            }

            Section {
                Picker("Escalation provider", selection: $providerRaw) {
                    Text("Automatic (private preferred)").tag("auto")
                    Text("Private compute only").tag("private")
                    Text("Gemini only").tag("gemini")
                }
                .accessibilityIdentifier("cloudProviderPicker")
            } header: {
                Text("Provider")
            } footer: {
                Text("Automatic uses your private server when configured, else Gemini, else everything stays on-device.")
            }

            Section {
                HStack {
                    Label("Device attestation",
                          systemImage: attestation.isSupported ? "checkmark.shield" : "exclamationmark.shield")
                    Spacer()
                    Text(attestationStatus)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .accessibilityIdentifier("attestationStatus")
                if !attestation.isSupported {
                    keyRow(label: "Dev token", key: $devToken, show: $showDevToken, placeholder: "dev-…")
                }
            } header: {
                Text("Device identity")
            } footer: {
                Text(attestation.isSupported
                     ? "This device authenticates to your server with App Attest — an anonymous per-device key, no account."
                     : "App Attest isn't available here (Simulator). Requests use a development bearer token — for testing only.")
            }

            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        if isTesting { ProgressView().scaleEffect(0.8).padding(.trailing, 4) }
                        Text(isTesting ? "Testing…" : "Test connection")
                    }
                }
                .disabled(endpoint.isEmpty || !isHTTPS || isTesting)
                if !testResult.isEmpty {
                    Text(testResult).font(.caption)
                        .foregroundStyle(testResult.hasPrefix("Success") ? .green : .red)
                }
            } header: {
                Text("Connection test")
            } footer: {
                Text("Privacy note: this is PCC-inspired, not Apple's Private Cloud Compute. The stateless / no-retention guarantees depend on you operating the server honestly — they are not cryptographically verifiable by the app, and attestation proves your device to the server, not the server to your device. Bytes sent here are counted as leaving your device in the Privacy Ledger.")
            }
        }
        .navigationTitle("Private Compute")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("privateCloudView")
        .onChange(of: endpoint) { _, value in
            KeychainStore.shared.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "pcs_endpoint")
        }
        .onChange(of: devToken) { _, value in
            KeychainStore.shared.set(value, forKey: DeviceAttestation.devTokenKey)
        }
    }

    private var isHTTPS: Bool {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return url.scheme?.lowercased() == "https"
    }

    private var attestationStatus: String {
        if attestation.isSupported {
            return KeychainStore.shared.string(forKey: DeviceAttestation.keyIdKey) != nil ? "Attested" : "Ready"
        }
        return "Simulator (dev token)"
    }

    private func testConnection() async {
        isTesting = true; testResult = ""
        defer { isTesting = false }
        do {
            let reply = try await PrivateComputeClient().generate(
                prompt: "ping", sessionId: "test", config: .deterministic, recordsLedger: false)
            testResult = "Success: \(reply.prefix(80))"
        } catch {
            testResult = "Failed: \(error.localizedDescription)"
        }
    }

    // Masked key row (mirrors SettingsView.apiKeyRow).
    @ViewBuilder
    private func keyRow(label: String, key: Binding<String>, show: Binding<Bool>, placeholder: String) -> some View {
        HStack {
            Text(label).layoutPriority(1)
            Spacer()
            if show.wrappedValue {
                TextField(placeholder, text: key).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).frame(maxWidth: 200)
            } else {
                SecureField(placeholder, text: key).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).frame(maxWidth: 200)
            }
            Button { show.wrappedValue.toggle() } label: {
                Image(systemName: show.wrappedValue ? "eye.slash" : "eye").foregroundStyle(.secondary).font(.caption)
            }
            .buttonStyle(.plain)
        }
    }
}
