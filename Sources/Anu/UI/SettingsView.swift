import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var modelManager = ModelManager.shared
    // API keys live in the vault. Settings never reads a saved value back:
    // the fields only take a new one (Vault screen shows values after Face ID).
    @ObservedObject private var vault = Vault.shared
    @State private var geminiAPIKey = ""
    @State private var searchAPIKey = ""
    @AppStorage("max_tokens") private var maxTokens = 512
    @AppStorage("temperature") private var temperature = 0.7
    @AppStorage("show_reasoning") private var showReasoning = false
    @AppStorage("speak_responses") private var speakResponses = false
    @AppStorage("fast_mode") private var fastMode = false
    @AppStorage("deep_reasoning") private var deepReasoning = false
    @AppStorage("smart_routing") private var smartRouting = false
    @AppStorage(ThinkingSetting.key) private var thinkFirst = false

    @State private var showGeminiKey = false
    @State private var showSearchKey = false
    @State private var testResult = ""
    @State private var isTesting = false

    var body: some View {
        NavigationStack {
            Form {
                // Memory — see and edit what Anu remembers
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
                    Text("Everything Anu remembers about you — visible, editable, and stored only on this device. Answers are grounded in these notes.")
                }

                // Connectors — MCP servers, REST APIs, app launching
                Section {
                    NavigationLink {
                        ConnectorsView()
                    } label: {
                        Label("Connectors", systemImage: "app.connected.to.app.below.fill")
                    }
                    .accessibilityIdentifier("connectorsRow")

                    NavigationLink {
                        SkillsView()
                    } label: {
                        Label("Skills", systemImage: "puzzlepiece.extension")
                    }
                    .accessibilityIdentifier("skillsRow")
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
                    Text("Save a prompt as a named action, then run it from here, the Share Sheet, a home-screen widget, or “Hey Siri, run … in Anu.”")
                }

                // Keyboard — Anu Keyboard and Rewrite with Anu (Android parity 20–21)
                Section {
                    NavigationLink {
                        KeyboardSettingsView()
                    } label: {
                        Label("Keyboard", systemImage: "keyboard")
                    }
                    .accessibilityIdentifier("keyboardRow")
                } header: {
                    Text("Writing everywhere")
                } footer: {
                    Text("Anu Keyboard and “Rewrite with Anu” in the share sheet: on-device AI writing in any app, with nothing changed until you tap Replace.")
                }

                // Model — swap the on-device brain (Gemma 4 E2B / E4B)
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
                    Text("Choose which Gemma 4 build runs on your device. Changing it swaps the brain immediately.")
                }

                // Connections
                Section {
                    apiKeyRow(
                        label: "Gemini API Key",
                        id: "geminiKeyField",
                        key: $geminiAPIKey,
                        show: $showGeminiKey,
                        placeholder: vault.contains(.gemini) ? "Saved in vault" : "AIza..."
                    )
                    .onSubmit { saveKeys() }
                    Link("Get a Gemini API key", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                        .font(.anuLabel)
                    NavigationLink {
                        PrivateCloudView()
                    } label: {
                        Label("Private Compute", systemImage: "lock.shield")
                    }
                    .accessibilityIdentifier("privateCloudRow")
                    NavigationLink {
                        MacBrainView()
                    } label: {
                        Label("Your Mac", systemImage: "desktopcomputer")
                    }
                    .accessibilityIdentifier("macBrainRow")
                } header: {
                    Text("Cloud Helper (Optional)")
                } footer: {
                    Text("Big writing and coding tasks can be handed to Google Gemini, or to a private compute server you operate (preferred when configured). Personal details are removed before anything leaves your device. Without either, everything runs locally.")
                }

                Section {
                    apiKeyRow(
                        label: "Brave Search Key",
                        id: "searchKeyField",
                        key: $searchAPIKey,
                        show: $showSearchKey,
                        placeholder: vault.contains(.braveSearch) ? "Saved in vault" : "BSA..."
                    )
                    .onSubmit { saveKeys() }
                    Link("Get a Brave Search key", destination: URL(string: "https://brave.com/search/api/")!)
                        .font(.anuLabel)
                } header: {
                    Text("Web Search (Optional)")
                } footer: {
                    Text("Optional. Enables live web search. Without a key, the agent reports that search is unavailable.")
                }

                // Voice — talk in, talk back
                Section {
                    Toggle("Speak Responses", isOn: $speakResponses)
                        .accessibilityIdentifier("speakToggle")
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Read replies aloud after each turn. Combined with the mic, this gives a hands-free, conversational back-and-forth. Assign “Talk to Anu” to the Action Button to start talking from anywhere.")
                }

                // Performance — speed vs. depth tradeoffs
                Section {
                    Toggle("Fast mode", isOn: $fastMode)
                        .accessibilityIdentifier("fastModeToggle")
                    Toggle("Deep reasoning", isOn: $deepReasoning)
                        .accessibilityIdentifier("deepReasoningToggle")
                    Toggle("Smart routing", isOn: $smartRouting)
                        .accessibilityIdentifier("smartRoutingToggle")
                    // Gemma 4's thought channel (ADR-077). Its reasoning shows
                    // collapsed under the answer, and in the trace when Show
                    // Reasoning & Thinking is on.
                    Toggle("Think before answering", isOn: $thinkFirst)
                        .accessibilityIdentifier("thinkingToggle")
                    NavigationLink {
                        PromptLabView()
                    } label: {
                        Label("Prompt lab", systemImage: "flask")
                    }
                    .accessibilityIdentifier("promptLabRow")
                } header: {
                    Text("Performance")
                } footer: {
                    Text("Fast mode gives instant single-shot replies (no tools or multi-step reasoning) — best for quick chats or the Simulator. Deep reasoning lets complex requests plan across multiple steps with a critic pass; it's more thorough but much slower (many model calls per reply). Smart routing asks the on-device model whether a task needs the larger cloud model — more accurate escalation, one extra quick on-device step per borderline turn; needs a cloud provider configured. Think before answering lets Gemma 4 reason first: the reasoning shows collapsed under the answer, and the first word comes much later. Prompt lab tries a prompt on the on-device model with no memory, tools or history. All off = the balanced default.")
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
                                .tint(Color.anuAccent)
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

                    NavigationLink {
                        ActivityView()
                    } label: {
                        Label("Activity", systemImage: "checklist")
                    }
                    .accessibilityIdentifier("activityRow")

                    NavigationLink {
                        VaultView()
                    } label: {
                        LabeledContent {
                            Text(vault.items.count == 1 ? "1 item" : "\(vault.items.count) items")
                        } label: {
                            Label("Vault", systemImage: "key.viewfinder")
                        }
                    }
                    .accessibilityIdentifier("vaultRow")

                    Toggle("Show Reasoning & Thinking", isOn: $showReasoning)
                        .accessibilityIdentifier("reasoningToggle")
                } header: {
                    Text("Privacy & Transparency")
                } footer: {
                    Text("The Privacy Ledger logs everything that leaves your device — to the cloud, an MCP server, a REST API, or another app — with the exact payload and what was redacted. Activity lists every action Anu took or was stopped from taking. Anything other people will see, or that leaves Anu, always waits for you to approve the exact content first. Show Reasoning reveals how the agent thinks: task classification, model routing, the model's raw thoughts, tool calls and observations — step by step under the chat.")
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
                                    .padding(.trailing, Space.xs)
                            }
                            Text(isTesting ? "Testing..." : "Test Gemini Connection")
                        }
                    }
                    .disabled(geminiAPIKey.isEmpty || isTesting)

                    if !testResult.isEmpty {
                        Text(testResult)
                            .font(.anuLabel)
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
            .onDisappear { saveKeys() }
            .toolbar {
                ToolbarItem(placement: .anuTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func apiKeyRow(label: String, id: String, key: Binding<String>, show: Binding<Bool>, placeholder: String) -> some View {
        HStack {
            Text(label)
                .layoutPriority(1)
            Spacer()
            if show.wrappedValue {
                TextField(placeholder, text: key)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .anuNoAutocorrect()
                    .frame(maxWidth: 200)
                    .accessibilityIdentifier(id)
            } else {
                SecureField(placeholder, text: key)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .anuNoAutocorrect()
                    .frame(maxWidth: 200)
                    .accessibilityIdentifier(id)
            }
            Button {
                show.wrappedValue.toggle()
            } label: {
                Image(systemName: show.wrappedValue ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
                    .font(.anuLabel)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(show.wrappedValue ? "Hide \(label)" : "Show \(label)")
        }
    }

    /// Stores any newly typed key in the vault with its host binding, then
    /// clears the field so the value doesn't linger in view state.
    private func saveKeys() {
        if !geminiAPIKey.isEmpty { try? KnownSecret.gemini.store(geminiAPIKey); geminiAPIKey = "" }
        if !searchAPIKey.isEmpty { try? KnownSecret.braveSearch.store(searchAPIKey); searchAPIKey = "" }
    }

    func testGeminiConnection() async {
        saveKeys()
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
