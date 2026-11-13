import SwiftUI
import PhotosUI

struct ChatView: View {
    /// Lets the empty state send the user to Settings when no model loaded.
    /// Owned by `ContentView`, which presents the sheet.
    var onOpenSettings: (() -> Void)?

    // Unified state access: every view observes the shared singletons directly
    // (matches SessionListView / SettingsView / ConnectorsView).
    @ObservedObject private var orchestrator = AgentOrchestrator.shared
    @ObservedObject private var approvals = AgentOrchestrator.shared.approvals
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
    @State private var showLiveCamera = false
    @State private var showImagePlayground = false
    @State private var showVoiceMode = false
    // Tracks which assistant reply has already been read aloud (avoid repeats).
    @State private var lastSpokenMessageID: UUID?

    /// Highest-priority thing happening right now. Listening wins over
    /// speaking so the orb tracks you the instant you interrupt.
    private var orbState: VoiceOrbState {
        if speech.isRecording { return .listening }
        if tts.isSpeaking { return .speaking }
        if orchestrator.isThinking { return .thinking }
        return .idle
    }

    private var orbLevel: Double {
        if speech.isRecording { return speech.level }
        if tts.isSpeaking { return tts.level }
        return 0
    }

    /// Opening voice mode starts listening straight away — a tap on the orb
    /// should never need a second tap to be heard.
    private func openVoiceMode() {
        showVoiceMode = true
        if !speech.isRecording { speech.toggle() }
    }

    /// Leaving voice mode releases the mic and the speaker; neither should
    /// keep running behind the chat.
    private func closeVoiceMode() {
        if speech.isRecording { speech.stop() }
        tts.stop()
        showVoiceMode = false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            StatusBar(status: orchestrator.status)

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Space.base) {
                        if orchestrator.messages.isEmpty {
                            EmptyStateView(
                                onSelect: sendSuggestion,
                                loadFailure: modelLoadFailure,
                                onOpenSettings: onOpenSettings
                            )
                        } else {
                            ForEach(orchestrator.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, Space.comfy)
                    .padding(.vertical, Space.base)
                }
                .onChange(of: orchestrator.messages.count) { _, _ in
                    if let lastId = orchestrator.messages.last?.id {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
                // Receipts are added to an answer already on screen, so the
                // count doesn't change; follow them so they're never hidden.
                .onChange(of: orchestrator.messages.last?.receipts?.count) { _, _ in
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
            if let data = pendingImageData, let image = Image(platformImageData: data) {
                HStack {
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                    Text("Image attached")
                        .font(.anuLabel)
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
                .padding(.horizontal, Space.comfy)
                .padding(.vertical, Space.tight)
                .background(Color.anuFill6)
            }

            // Input area — voice-first: the mic is the primary affordance
            InputBar(
                text: $inputText,
                isFocused: $isInputFocused,
                isThinking: orchestrator.isThinking,
                isRecording: speech.isRecording,
                orbState: orbState,
                orbLevel: orbLevel,
                showTrace: $showTrace,
                hasTrace: !orchestrator.reasoningSteps.isEmpty,
                photoItem: $photoItem,
                onSend: sendMessage,
                onClear: orchestrator.clearConversation,
                onStop: orchestrator.cancel,
                onMic: openVoiceMode,
                onCamera: openCamera,
                onCreateImage: openImageCreation,
                onLiveCamera: liveCameraAction
            )
        }
        .imageCreationSheet(isPresented: $showImagePlayground, concept: inputText) { data in
            orchestrator.presentGeneratedImage(data, caption: "Generated image")
        }
        .sheet(isPresented: $showPrivacy) {
            NavigationStack { PrivacyView(isModal: true) }
        }
        .voiceModeCover(isPresented: $showVoiceMode) {
            VoiceModeView(
                speech: speech,
                tts: tts,
                onToggleListening: speech.toggle,
                onDismiss: closeVoiceMode
            )
        }
        // The exact payload the broker will run, waiting on the user. One
        // sheet for the whole run: after an edit the broker asks again, and the
        // sheet shows the checked payload in place (keyed by request id).
        .sheet(isPresented: Binding(
            get: { approvals.pending != nil },
            set: { if !$0 { approvals.cancelAll() } }
        )) {
            if let request = approvals.pending {
                ApprovalSheet(request: request) { decision in
                    approvals.decide(request.id, decision)
                }
                .id(request.id)
            }
        }
        #if canImport(UIKit) && canImport(AVFoundation)
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView(
                onCapture: { data in
                    pendingImageData = data
                    showCamera = false
                },
                onCancel: { showCamera = false }
            )
            .ignoresSafeArea()
        }
        #endif
        #if os(iOS)
        .fullScreenCover(isPresented: $showLiveCamera) {
            LiveCameraView(onAsk: askFromLiveCamera, onClose: { showLiveCamera = false })
        }
        #endif
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
            consumePendingLiveCamera()
        }
        // Auto-start the mic when launched via the "Talk to Anu" intent
        // (Action Button / Siri). The intent set a one-shot flag.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { consumePendingVoiceStart(); consumePendingLiveCamera() }
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

    /// A tapped suggestion behaves exactly like typing it and hitting send —
    /// no separate path to keep in sync.
    private func sendSuggestion(_ prompt: String) {
        guard !orchestrator.isThinking else { return }
        inputText = prompt
        sendMessage()
    }

    /// Non-nil only when the model genuinely failed to load. `.loading` isn't
    /// a failure — the status bar already covers that.
    private var modelLoadFailure: String? {
        if case .failed(let reason) = orchestrator.modelLoadState { return reason }
        return nil
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

    /// "+" → Live Camera (iOS only; the Mac has no live camera page).
    private var liveCameraAction: (() -> Void)? {
        #if os(iOS)
        return { tts.stop(); showLiveCamera = true }
        #else
        return nil
        #endif
    }

    /// "Ask Anu about this": the frozen frame goes through the ordinary photo
    /// path, which keeps image turns on the device.
    private func askFromLiveCamera(_ jpeg: Data, _ prompt: String) {
        showLiveCamera = false
        tts.stop()
        Task { await orchestrator.run(userMessage: prompt, imageData: jpeg) }
    }

    /// Consumes the one-shot flag set by `OpenLiveCameraIntent`.
    private func consumePendingLiveCamera() {
        #if os(iOS)
        if OpenLiveCameraIntent.consumePending() { tts.stop(); showLiveCamera = true }
        #endif
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
        // "Talk to Anu" is the hands-free entry point, so it lands in voice
        // mode rather than dropping dictation into a text field nobody is
        // looking at.
        openVoiceMode()
    }
}
