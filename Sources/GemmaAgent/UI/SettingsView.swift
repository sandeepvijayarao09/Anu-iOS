import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var modelManager = ModelManager.shared
    // API keys live in the Keychain, not UserDefaults
    @State private var geminiAPIKey = KeychainStore.shared.string(forKey: "gemini_api_key") ?? ""
    @State private var searchAPIKey = KeychainStore.shared.string(forKey: "search_api_key") ?? ""
    @AppStorage("max_tokens") private var maxTokens = 512
    @AppStorage("temperature") private var temperature = 0.7
    @AppStorage("show_reasoning") private var showReasoning = false

    @State private var showGeminiKey = false
    @State private var showSearchKey = false
    @State private var testResult = ""
    @State private var isTesting = false

    var body: some View {
        NavigationStack {
            Form {
                // Memory — see and edit what Gemma remembers
                Section {
                    NavigationLink {
                        MemoryView()
                    } label: {
                        Label("Memory", systemImage: "brain.head.profile")
                    }
                    .accessibilityIdentifier("memoryRow")
                } header: {
                    Text("Memory")
                } footer: {
                    Text("Everything Gemma remembers about you — visible, editable, and stored only on this device. Answers are grounded in these notes.")
                }

                // Connectors — MCP servers, REST APIs, app launching
                Section {
                    NavigationLink {
                        ConnectorsView()
                    } label: {
                        Label("Connectors", systemImage: "app.connected.to.app.below.fill")
                    }
                    .accessibilityIdentifier("connectorsRow")
                } header: {
                    Text("Connectors")
                } footer: {
                    Text("Connect the agent to MCP servers, REST APIs, Apple Shortcuts, and other apps. Discovered tools show up in the chat with every call visible.")
                }

                // Workflows — saved, re-runnable prompt recipes
                Section {
                    NavigationLink {
                        WorkflowsView()
                    } label: {
                        Label("Workflows", systemImage: "play.square.stack")
                    }
                    .accessibilityIdentifier("workflowsRow")
                } header: {
                    Text("Workflows")
                } footer: {
                    Text("Save a prompt as a named action, then run it from here, the Share Sheet, a home-screen widget, or “Hey Siri, run … in GemmaAgent.”")
                }

                // Model — swap the on-device brain (incl. Apple's own)
                Section {
                    NavigationLink {
                        ModelManagerView()
                    } label: {
                        HStack {
                            Label("On-device Model", systemImage: "cpu")
                            Spacer()
                            Text(modelManager.selectedOption.displayName)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("modelRow")
                } header: {
                    Text("Model")
                } footer: {
                    Text("Choose which model runs on your device — open models or Apple's own on-device model, all behind the same engine. Changing it swaps the brain immediately.")
                }

                // Connections
                Section {
                    apiKeyRow(
                        label: "Gemini API Key",
                        key: $geminiAPIKey,
                        show: $showGeminiKey,
                        placeholder: "AIza..."
                    )
                    Link("Get a Gemini API key", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                        .font(.caption)
                } header: {
                    Text("Cloud Helper (Optional)")
                } footer: {
                    Text("Big writing and coding tasks can be handed to Google Gemini. Personal details are removed before anything leaves your device. Without a key, everything runs locally.")
                }

                Section {
                    apiKeyRow(
                        label: "Brave Search Key",
                        key: $searchAPIKey,
                        show: $showSearchKey,
                        placeholder: "BSA..."
                    )
                    Link("Get a Brave Search key", destination: URL(string: "https://brave.com/search/api/")!)
                        .font(.caption)
                } header: {
                    Text("Web Search (Optional)")
                } footer: {
                    Text("Optional. Enables live web search. Without a key, the agent reports that search is unavailable.")
                }

                // Advanced — tucked away; defaults are good
                Section {
                    DisclosureGroup("Advanced") {
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Creativity")
                                Spacer()
                                Text(temperature < 0.35 ? "Precise" : (temperature < 0.7 ? "Balanced" : "Creative"))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $temperature, in: 0.0...1.0, step: 0.05)
                                .tint(.blue)
                        }
                        HStack {
                            Text("Longest reply")
                            Spacer()
                            Stepper("\(maxTokens) tokens", value: $maxTokens, in: 64...2048, step: 64)
                        }
                    }
                } footer: {
                    Text("The defaults work well — adjust only if you want noticeably different behavior.")
                }

                // Reasoning visibility + the privacy ledger
                Section {
                    NavigationLink {
                        PrivacyView()
                    } label: {
                        Label("Privacy Ledger", systemImage: "lock.shield")
                    }
                    .accessibilityIdentifier("privacyRow")

                    Toggle("Show Reasoning & Thinking", isOn: $showReasoning)
                        .accessibilityIdentifier("reasoningToggle")
                } header: {
                    Text("Privacy & Transparency")
                } footer: {
                    Text("The Privacy Ledger logs everything that leaves your device — to the cloud, an MCP server, a REST API, or another app — with the exact payload and what was redacted. Show Reasoning reveals how the agent thinks: task classification, model routing, the model's raw thoughts, tool calls and observations — step by step under the chat.")
                }

                // Test connection
                Section {
                    Button {
                        Task { await testGeminiConnection() }
                    } label: {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .padding(.trailing, 4)
                            }
                            Text(isTesting ? "Testing..." : "Test Gemini Connection")
                        }
                    }
                    .disabled(geminiAPIKey.isEmpty || isTesting)

                    if !testResult.isEmpty {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testResult.contains("Success") ? .green : .red)
                    }
                } header: {
                    Text("Connection Test")
                }

                // Model info
                Section {
                    InfoRow(label: "On-device brain", value: modelManager.selectedOption.displayName)
                    InfoRow(label: "Cloud helper", value: "Gemini 2.0 Flash")
                                        InfoRow(label: "App Version", value: "1.0.0")
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onChange(of: geminiAPIKey) { _, newValue in
                KeychainStore.shared.set(newValue, forKey: "gemini_api_key")
            }
            .onChange(of: searchAPIKey) { _, newValue in
                KeychainStore.shared.set(newValue, forKey: "search_api_key")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func apiKeyRow(label: String, key: Binding<String>, show: Binding<Bool>, placeholder: String) -> some View {
        HStack {
            Text(label)
                .layoutPriority(1)
            Spacer()
            if show.wrappedValue {
                TextField(placeholder, text: key)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(maxWidth: 200)
            } else {
                SecureField(placeholder, text: key)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(maxWidth: 200)
            }
            Button {
                show.wrappedValue.toggle()
            } label: {
                Image(systemName: show.wrappedValue ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(show.wrappedValue ? "Hide \(label)" : "Show \(label)")
        }
    }

    private func testGeminiConnection() async {
        isTesting = true
        testResult = ""
        defer { isTesting = false }

        let client = GeminiClient()
        do {
            let response = try await client.generate(prompt: "Say 'Connection successful' in exactly those two words.", config: GeminiGenerationConfig(maxOutputTokens: 20, temperature: 0, topP: 1, topK: 1))
            testResult = "Success: \(response.trimmingCharacters(in: .whitespacesAndNewlines))"
        } catch {
            testResult = "Failed: \(error.localizedDescription)"
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}
