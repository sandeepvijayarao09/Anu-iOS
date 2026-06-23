import SwiftUI
import PhotosUI

struct ChatView: View {
    // Unified state access: every view observes the shared singletons directly
    // (matches SessionListView / SettingsView / ConnectorsView).
    @ObservedObject private var orchestrator = AgentOrchestrator.shared
    @ObservedObject private var ledger = PrivacyLedger.shared
    @StateObject private var speech = SpeechRecognizer()
    @StateObject private var tts = SpeechSynthesizer()
    @Environment(\.scenePhase) private var scenePhase
    @State private var inputText = ""
    // Persisted: same storage as the "Show Reasoning & Thinking" Settings toggle
    @AppStorage("show_reasoning") private var showTrace = false
    @FocusState private var isInputFocused: Bool
    @State private var scrollProxy: ScrollViewProxy?
    @State private var photoItem: PhotosPickerItem?
    @State private var pendingImageData: Data?
    @State private var showPrivacy = false
    @State private var showCamera = false
    @State private var showImagePlayground = false
    // Tracks which assistant reply has already been read aloud (avoid repeats).
    @State private var lastSpokenMessageID: UUID?

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
                // Rebuild the list (and reset scroll) when the active sandbox changes.
                .id(orchestrator.activeSessionID)
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
                onMic: speech.toggle,
                onCamera: openCamera,
                onCreateImage: openImageCreation
            )
        }
        .imageCreationSheet(isPresented: $showImagePlayground, concept: inputText) { data in
            orchestrator.presentGeneratedImage(data, caption: "Generated image")
        }
        .sheet(isPresented: $showPrivacy) {
            NavigationStack { PrivacyView(isModal: true) }
        }
        .alert("Allow this action?", isPresented: Binding(
            get: { orchestrator.pendingConfirmation != nil },
            set: { if !$0 { orchestrator.resolvePendingConfirmation(false) } }
        ), presenting: orchestrator.pendingConfirmation) { _ in
            Button("Allow") { orchestrator.resolvePendingConfirmation(true) }
            Button("Don't Allow", role: .cancel) { orchestrator.resolvePendingConfirmation(false) }
        } message: { pending in
            Text("The agent wants to run “\(pending.toolName)”.\n\n\(pending.summary)")
        }
        .fullScreenCover(isPresented: $showCamera) {
            #if canImport(UIKit) && canImport(AVFoundation)
            CameraCaptureView(
                onCapture: { data in
                    pendingImageData = data
                    showCamera = false
                },
                onCancel: { showCamera = false }
            )
            .ignoresSafeArea()
            #endif
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
            consumePendingVoiceStart()
        }
        // Auto-start the mic when launched via the "Talk to Anu" intent
        // (Action Button / Siri). The intent set a one-shot flag.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { consumePendingVoiceStart() }
        }
        // Speak the final reply aloud when a turn settles (if the user enabled
        // spoken replies). Completes the voice loop: talk in, talk back.
        .onChange(of: orchestrator.isThinking) { _, thinking in
            guard !thinking, let last = orchestrator.messages.last,
                  last.role == .assistant, !last.isStreaming,
                  last.id != lastSpokenMessageID else { return }
            lastSpokenMessageID = last.id
            tts.speakIfEnabled(last.content)
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
        tts.stop()   // don't talk over a fresh request
        inputText = ""
        let image = pendingImageData
        pendingImageData = nil
        Task {
            await orchestrator.run(userMessage: text, imageData: image)
        }
    }

    /// Opens the live camera for point-and-ask, or — in the Simulator / on a
    /// device without a camera — guides the user to the photo button instead.
    private func openCamera() {
        #if canImport(UIKit) && canImport(AVFoundation)
        if CameraCaptureView.isAvailable {
            tts.stop()
            showCamera = true
            return
        }
        #endif
        orchestrator.messages.append(.system("No camera here — use the photo button to attach an image instead."))
    }

    /// Opens Apple's Image Playground to create an image, or explains when it's
    /// unavailable (older OS / no Apple Intelligence).
    private func openImageCreation() {
        guard ImageCreation.isAvailable else {
            orchestrator.messages.append(.system("Image creation needs iOS 18.1+ with Apple Intelligence."))
            return
        }
        tts.stop()
        showImagePlayground = true
    }

    /// Consumes the one-shot flag set by `StartVoiceIntent` (Action Button /
    /// "Talk to Anu") and starts listening without an extra tap.
    private func consumePendingVoiceStart() {
        guard UserDefaults.standard.bool(forKey: StartVoiceIntent.pendingVoiceKey) else { return }
        UserDefaults.standard.set(false, forKey: StartVoiceIntent.pendingVoiceKey)
        guard !speech.isRecording, !orchestrator.isThinking else { return }
        tts.stop()
        speech.toggle()
    }
}
