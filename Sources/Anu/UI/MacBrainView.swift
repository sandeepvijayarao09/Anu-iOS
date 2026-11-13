import SwiftUI

/// Settings → Your Mac: the user's own Mac running Ollama as the top model
/// (ADR-113). An address on the user's network (plain HTTP straight to
/// Ollama), or a pairing code from `Scripts/mac-brain.py` (HTTPS pinned to the
/// Mac's certificate, with a token the vault keeps).
struct MacBrainView: View {
    @State private var address = MacBrainConfig.load()?.destination ?? ""
    @State private var model = MacBrainConfig.load()?.model ?? ""
    @State private var pairingCode = ""
    @State private var models: [String] = []
    @State private var status = ""
    @State private var statusIsError = false
    @State private var isTesting = false
    @State private var saved = MacBrainConfig.load()
    @AppStorage(CloudProvider.preferenceKey) private var providerRaw = "auto"
    @ObservedObject private var vault = Vault.shared

    var body: some View {
        Form {
            Section {
                TextField("192.168.1.20:11434", text: $address)
                    .textFieldStyle(.plain)
                    .anuURLField()
                    .accessibilityIdentifier("macAddressField")
                    .onSubmit { saveAddress() }
                Button("Save address") { saveAddress() }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("macSaveAddress")
            } header: {
                Text("Mac address")
            } footer: {
                Text("Host and port of Ollama on your Mac (default port 11434). Plain HTTP works only for an address on your own network, and no secret is ever sent over it. On the Mac, start Ollama with OLLAMA_HOST=0.0.0.0 so the phone can reach it.")
            }

            Section {
                TextField("anu-mac://…", text: $pairingCode)
                    .textFieldStyle(.plain)
                    .anuNoAutocorrect()
                    .accessibilityIdentifier("macPairingField")
                Button("Pair") { pair() }
                    .disabled(pairingCode.isEmpty)
                if let saved, saved.pin != nil {
                    Label(vault.contains(.macBrain) ? "Paired over HTTPS, token in the vault" : "Pinned, but no token",
                          systemImage: "lock.fill")
                        .font(.anuLabel).foregroundStyle(.secondary)
                }
            } header: {
                Text("Pairing code (optional)")
            } footer: {
                Text("For HTTPS with a token: run Scripts/mac-brain.py on the Mac and paste the code it prints. Anu then trusts exactly that Mac's certificate, and the token goes into the vault, sent only to that address.")
            }

            Section {
                if models.isEmpty {
                    TextField("Model (e.g. \(MacBrainConfig.defaultModel))", text: $model)
                        .textFieldStyle(.plain)
                        .anuNoAutocorrect()
                        .onSubmit { saveModel() }
                } else {
                    Picker("Model", selection: $model) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Which Ollama model answers. Test connection lists the ones your Mac has. Through mac-brain.py the Mac chooses.")
            }
            .onChange(of: model) { _, _ in saveModel() }

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        if isTesting { ProgressView().scaleEffect(0.8).padding(.trailing, Space.xs) }
                        Text(isTesting ? "Testing…" : "Test connection")
                    }
                }
                .disabled(saved == nil || isTesting)
                .accessibilityIdentifier("macTestConnection")
                if !status.isEmpty {
                    Text(status).font(.anuLabel).foregroundStyle(statusIsError ? .red : .green)
                }
                if saved != nil {
                    Button("Forget this Mac", role: .destructive) { forget() }
                }
            } header: {
                Text("Connection")
            } footer: {
                Text(providerFooter)
            }
        }
        .navigationTitle("Your Mac")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("macBrainView")
    }

    private var providerFooter: String {
        let use: String
        switch CloudProvider(rawValue: providerRaw) ?? .auto {
        case .mac: use = "Big tasks go to your Mac."
        case .auto: use = "In Automatic mode your Mac is used when no private server is set up, in Gemini's place."
        case .gemini, .privateCloud: use = "Your escalation provider is set to something else (Private Compute → Provider)."
        }
        return use + " A request to your Mac crosses your Wi-Fi, so it is treated like the cloud: personal details are redacted first, it is recorded in the Privacy Ledger, and photos stay on your phone."
    }

    private func saveAddress() {
        let previous = saved
        let keepPin = previous.flatMap { old in
            MacBrainConfig.parse(address: address, pin: old.pin).flatMap { $0.host == old.host ? old.pin : nil }
        }
        guard let config = MacBrainConfig.parse(address: address, pin: keepPin, model: model) else {
            show("That isn't an address on your own network. Use host:port, or pair over HTTPS.", error: true)
            return
        }
        // A token is bound to its Mac's host; a new host can't use it.
        if previous?.host != config.host || !config.isHTTPS { vault.delete(.macBrain) }
        config.save()
        saved = config
        address = config.destination
        models = []
        show("Saved \(config.baseURL.absoluteString)", error: false)
    }

    private func pair() {
        guard let code = MacPairing.parse(pairingCode) else {
            show("That isn't a pairing code from mac-brain.py.", error: true)
            return
        }
        do {
            try MacPairing.storeToken(code.token, for: code.config)
        } catch {
            show((error as? VaultError)?.errorDescription ?? error.localizedDescription, error: true)
            return
        }
        var config = code.config
        config.model = ""   // the gateway chooses the model
        config.save()
        saved = config
        address = config.destination
        model = ""
        pairingCode = ""
        show("Paired with \(config.destination)", error: false)
    }

    private func saveModel() {
        guard var config = saved else { return }
        config.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        config.save()
        saved = config
    }

    private func forget() {
        MacBrainConfig.clear()
        vault.delete(.macBrain)
        saved = nil
        address = ""
        model = ""
        models = []
        show("Forgot your Mac", error: false)
    }

    private func test() async {
        isTesting = true
        defer { isTesting = false }
        do {
            let health = try await MacBrainClient(config: saved).health()
            models = health.models
            if !models.isEmpty, !models.contains(model), saved?.pin == nil {
                model = models.contains(MacBrainConfig.defaultModel) ? MacBrainConfig.defaultModel : models[0]
            }
            show("Connected: \(health.summary)" + (models.isEmpty ? "" : " · \(models.count) model\(models.count == 1 ? "" : "s")"),
                 error: false)
        } catch {
            show("Failed: " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription), error: true)
        }
    }

    private func show(_ text: String, error: Bool) {
        status = text
        statusIsError = error
    }
}
