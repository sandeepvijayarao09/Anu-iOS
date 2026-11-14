import SwiftUI

/// Settings → Prompt lab (ADR-080): try a prompt on the on-device model with
/// no memory, tools or history. A template writes an instruction the user can
/// change; then the prompt and sampling. It's a side conversation: nothing is
/// saved into chats, and it never reaches the cloud.
struct PromptLabView: View {
    @StateObject private var lab = PromptLabModel()
    @ObservedObject private var orchestrator = AgentOrchestrator.shared
    /// Run closes the keyboard so the answer below isn't hidden under it.
    @FocusState private var typing: Bool

    var body: some View {
        Form {
            Section {
                Picker("Template", selection: Binding(get: { lab.template }, set: { lab.choose($0) })) {
                    ForEach(LabTemplate.allCases) { Text($0.rawValue).tag($0) }
                }
                .accessibilityIdentifier("labTemplate")
                if !lab.template.options.isEmpty {
                    Picker("Style", selection: Binding(
                        get: { lab.option ?? lab.template.options[0] },
                        set: { lab.choose(option: $0) })) {
                        ForEach(lab.template.options, id: \.self) { Text($0).tag($0) }
                    }
                }
                TextField("Instruction (optional)", text: $lab.instruction, axis: .vertical)
                    .lineLimit(2...5)
                    .focused($typing)
                    .accessibilityIdentifier("labInstruction")
            } header: {
                Text("Instruction")
            }

            Section("Prompt") {
                TextField("What to try", text: $lab.prompt, axis: .vertical)
                    .lineLimit(3...10)
                    .focused($typing)
                    .accessibilityIdentifier("labPrompt")
            }

            Section {
                if lab.running {
                    Button(role: .destructive) { lab.stop() } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .accessibilityIdentifier("labStop")
                } else {
                    Button { typing = false; lab.run() } label: {
                        Label("Run", systemImage: "play.circle")
                    }
                    .disabled(!lab.canRun)
                    .accessibilityIdentifier("labRun")
                }
            }

            if let reasoning = lab.reasoning {
                Section { ReasoningDisclosure(text: reasoning) }
            }

            if lab.running || !lab.output.isEmpty || lab.error != nil {
                Section {
                    if let error = lab.error {
                        Text(error).foregroundStyle(Color.anuDestructive)
                    } else if lab.output.isEmpty {
                        ProgressView()
                    } else {
                        Text(lab.output)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("labOutput")
                    }
                    if lab.stopped && !lab.output.isEmpty {
                        Text("Stopped before the end").font(.anuLabel).foregroundStyle(.secondary)
                    } else if lab.cut {
                        Text("Cut at the longest answer").font(.anuLabel).foregroundStyle(.secondary)
                    }
                    if let speed = lab.speed {
                        Text(speed).font(.anuCode).foregroundStyle(.secondary)
                            .accessibilityIdentifier("labSpeed")
                    }
                    if !lab.output.isEmpty {
                        Button {
                            Clipboard.copy(lab.output)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                } header: {
                    Text("Answer")
                }
            }
            Section {
                DisclosureGroup("Sampling · temperature \(String(format: "%.2f", lab.sampling.temperature)), top-K \(lab.sampling.topK)") {
                LabeledContent("Model", value: AnswerDetailsText.shortModelName(orchestrator.model.modelName))
                sliderRow("Temperature", value: $lab.sampling.temperature, range: 0...1.5, step: 0.05,
                          text: String(format: "%.2f", lab.sampling.temperature))
                Stepper("Top-K  \(lab.sampling.topK)", value: $lab.sampling.topK, in: 1...100)
                sliderRow("Top-P", value: $lab.sampling.topP, range: 0...1, step: 0.05,
                          text: String(format: "%.2f", lab.sampling.topP))
                Stepper("Longest answer  \(lab.sampling.maxTokens)", value: $lab.sampling.maxTokens, in: 64...2048, step: 64)
                Toggle("Think first", isOn: $lab.sampling.thinking)
                    .disabled(!orchestrator.model.supportsThinking)
                    .accessibilityIdentifier("labThinking")
                Button("Greedy (same answer every run)") { lab.useGreedy() }
                }
                .accessibilityIdentifier("labSampling")
            } footer: {
                if !orchestrator.model.supportsThinking {
                    Text("This model has no reasoning channel, so Think first is off.")
                }
            }

        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Prompt lab")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onDisappear { lab.stop() }
        .accessibilityIdentifier("promptLabView")
    }


    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, text: String) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(label)
                Spacer()
                Text(text).foregroundStyle(.secondary).font(.anuCode)
            }
            Slider(value: value, in: range, step: step).tint(Color.anuAccent)
        }
    }
}
