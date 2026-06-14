import SwiftUI
import PhotosUI

struct ChatView: View {
    @EnvironmentObject var orchestrator: AgentOrchestrator
    @ObservedObject private var ledger = PrivacyLedger.shared
    @StateObject private var speech = SpeechRecognizer()
    @State private var inputText = ""
    // Persisted: same storage as the "Show Reasoning & Thinking" Settings toggle
    @AppStorage("show_reasoning") private var showTrace = false
    @FocusState private var isInputFocused: Bool
    @State private var scrollProxy: ScrollViewProxy? = nil
    @State private var photoItem: PhotosPickerItem?
    @State private var pendingImageData: Data?
    @State private var showPrivacy = false

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            StatusBar(status: orchestrator.status)

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if orchestrator.messages.isEmpty {
                            EmptyStateView()
                        } else {
                            ForEach(orchestrator.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: orchestrator.messages.count) { _, _ in
                    if let lastId = orchestrator.messages.last?.id {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if let lastId = orchestrator.messages.last?.id {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }

            // Per-turn privacy summary: what left the device this turn.
            // Appears once a turn settles so it doesn't flicker mid-generation;
            // hidden when the chat is empty (e.g. after Clear) — the full record
            // still lives in Settings → Privacy.
            if !orchestrator.isThinking, !orchestrator.messages.isEmpty,
               let summary = ledger.lastTurnSummary {
                Divider()
                PrivacyChip(summary: summary) { showPrivacy = true }
            }

            // Reasoning trace (collapsible)
            if showTrace && !orchestrator.reasoningSteps.isEmpty {
                Divider()
                AgentTraceView(steps: orchestrator.reasoningSteps)
                    .frame(maxHeight: 200)
            }

            Divider()

            // Attached image preview
            if let data = pendingImageData, let uiImage = UIImage(data: data) {
                HStack {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("Image attached")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        pendingImageData = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Remove attached image")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color(.systemGray6))
            }

            // Input area — voice-first: the mic is the primary affordance
            InputBar(
                text: $inputText,
                isFocused: $isInputFocused,
                isThinking: orchestrator.isThinking,
                isRecording: speech.isRecording,
                showTrace: $showTrace,
                hasTrace: !orchestrator.reasoningSteps.isEmpty,
                photoItem: $photoItem,
                onSend: sendMessage,
                onClear: orchestrator.clearConversation,
                onStop: orchestrator.cancel,
                onMic: speech.toggle
            )
        }
        .sheet(isPresented: $showPrivacy) {
            NavigationStack { PrivacyView(isModal: true) }
        }
        .task {
            await orchestrator.setup()
        }
        .onAppear {
            // Voice-first: a finished dictation sends immediately
            speech.onFinalTranscript = { final in
                inputText = final
                sendMessage()
            }
        }
        .onChange(of: speech.transcript) { _, live in
            if speech.isRecording { inputText = live }
        }
        .onChange(of: speech.errorMessage) { _, error in
            if let error { inputText = ""; orchestrator.messages.append(.system(error)) }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    pendingImageData = data
                }
                photoItem = nil
            }
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !orchestrator.isThinking else { return }
        inputText = ""
        let image = pendingImageData
        pendingImageData = nil
        Task {
            await orchestrator.run(userMessage: text, imageData: image)
        }
    }
}

// MARK: - Status Bar

private struct StatusBar: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .overlay {
                    if isAnimating {
                        Circle()
                            .stroke(statusColor, lineWidth: 1)
                            .scaleEffect(1.5)
                            .opacity(0.5)
                    }
                }

            Text(status.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Image(systemName: status.iconName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    var statusColor: Color {
        switch status {
        case .idle: return .green
        case .planning, .thinking, .streaming, .verifying: return .blue
        case .callingTool: return .orange
        case .escalating: return .purple
        case .error: return .red
        }
    }

    var isAnimating: Bool {
        switch status {
        case .planning, .thinking, .streaming, .callingTool, .escalating, .verifying: return true
        default: return false
        }
    }
}

// MARK: - Input Bar

private struct InputBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let isThinking: Bool
    let isRecording: Bool
    @Binding var showTrace: Bool
    let hasTrace: Bool
    @Binding var photoItem: PhotosPickerItem?
    @State private var actionPulse = 0
    let onSend: () -> Void
    let onClear: () -> Void
    let onStop: () -> Void
    let onMic: () -> Void

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            // Trace toggle
            if hasTrace {
                Button {
                    withAnimation(.spring(duration: 0.3)) {
                        showTrace.toggle()
                    }
                } label: {
                    Image(systemName: showTrace ? "brain.fill" : "brain")
                        .foregroundStyle(showTrace ? .blue : .secondary)
                        .font(.system(size: 18))
                }
                .accessibilityLabel(showTrace ? "Hide reasoning trace" : "Show reasoning trace")
                .accessibilityIdentifier("traceToggle")
            }

            // Clear button
            Button {
                onClear()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 18))
            }
            .accessibilityLabel("Clear conversation")
            .accessibilityIdentifier("clearButton")

            // Photo attach (multimodal input)
            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 18))
            }
            .accessibilityLabel("Attach an image")
            .accessibilityIdentifier("photoButton")

            // Text input (live dictation streams in here too)
            TextField(isRecording ? "Listening…" : "Message…", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused(isFocused)
                .submitLabel(.send)
                .onSubmit {
                    onSend()
                }
                .disabled(isThinking)
                .accessibilityIdentifier("messageField")

            // Primary action — voice-first: mic until there's text or work
            if isThinking {
                Button { actionPulse += 1; onStop() } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("Stop generating")
                .accessibilityIdentifier("stopButton")
            } else if isRecording {
                Button { actionPulse += 1; onMic() } label: {
                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.red)
                        // Reduce Motion: the red tint alone signals recording;
                        // skip the continuous pulse
                        .symbolEffect(.pulse, isActive: !reduceMotion)
                }
                .accessibilityLabel("Stop recording and send")
                .accessibilityIdentifier("micButton")
            } else if hasText {
                Button { actionPulse += 1; onSend() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.blue)
                }
                .accessibilityLabel("Send message")
                .accessibilityIdentifier("sendButton")
            } else {
                Button { actionPulse += 1; onMic() } label: {
                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.blue)
                }
                .accessibilityLabel("Start voice input")
                .accessibilityIdentifier("micButton")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background)
        // Native iOS 17 haptics on every primary action
        .sensoryFeedback(.impact(flexibility: .soft), trigger: actionPulse)
    }
}

// MARK: - Empty State

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 64))
                .foregroundStyle(.blue.gradient)

            Text("GemmaAgent")
                .font(.title2.bold())

            Text("An on-device agentic AI powered by Gemma 4B with Gemini escalation")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 8) {
                CapabilityRow(icon: "cpu", text: "Local inference with Gemma 4B")
                CapabilityRow(icon: "arrow.up.circle", text: "Escalates complex tasks to Gemini")
                CapabilityRow(icon: "wrench", text: "Uses tools: calculator, web search")
                CapabilityRow(icon: "brain", text: "ReAct reasoning loop")
            }
            .padding(.top, 8)
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
    }
}

private struct CapabilityRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
