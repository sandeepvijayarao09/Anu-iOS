import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

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
    @StateObject private var voiceNotes = VoiceNoteController()
    @StateObject private var voiceLoop = VoiceLoop()
    @AppStorage(WakeSettings.enabledKey) private var heyAnu = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var inputText = ""
    // Persisted: same storage as the "Show Reasoning & Thinking" Settings toggle
    @AppStorage("show_reasoning") private var showTrace = false
    @FocusState private var isInputFocused: Bool
    @State private var scrollProxy: ScrollViewProxy?
    // Up to four photos and one PDF waiting above the composer (ADR-094/095).
    @StateObject private var composer = AttachmentComposer()
    @ObservedObject private var sharedInbox = SharedAttachmentInbox.shared
    @State private var showPrivacy = false
    @State private var showCamera = false
    @State private var showLiveCamera = false
    @State private var showImagePlayground = false
    @State private var showVoiceMode = false
    /// Live talk's Live Activity, so it goes on behind other apps (ADR-108).
    @StateObject private var liveTalkPresence = LiveTalkPresence()
    /// The Screenshots picker ("Ask About My Screen", ADR-083's iOS form).
    @State private var showScreenPicker = false

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
    /// Voice mode is live talk (ADR-129): it listens, answers aloud, and
    /// listens again by itself; talking over Anu stops it.
    private func openVoiceMode(listen: Bool = true) {
        voiceLoop.stopWake()
        showVoiceMode = true
        speech.keepsSessionActive = true
        tts.conversational = true
        voiceLoop.startLiveTalk(listen: listen)
        liveTalkPresence.start()
    }

    /// Leaving voice mode releases the mic and the speaker; neither should
    /// keep running behind the chat.
    private func closeVoiceMode() {
        voiceLoop.stopLiveTalk()
        liveTalkPresence.end()
        speech.keepsSessionActive = false
        tts.conversational = false
        if speech.isRecording { speech.stop() }
        tts.stop()
        showVoiceMode = false
    }

    /// What live talk is doing, for its Live Activity; nil when it's off.
    private var liveTalkPhase: LiveTalkPhase? {
        LiveTalkPhase.current(active: voiceLoop.liveTalk.active, muted: voiceLoop.liveTalk.muted,
                              listening: speech.isRecording, speaking: tts.isSpeaking,
                              thinking: orchestrator.isThinking, awaitingApproval: approvals.pending != nil)
    }

    /// "Hey Anu" listens only while Anu is open and nothing else holds the mic.
    private var wakeEligible: Bool {
        heyAnu && scenePhase == .active && !showVoiceMode && !speech.isRecording && !tts.isSpeaking
            && !orchestrator.isThinking && voiceNotes.phase != .recording && voiceNotes.phase != .transcribing
    }

    private func refreshWake() {
        voiceLoop.updateWake(eligible: wakeEligible) { request in
            // "Hey Anu, what's on my calendar?" — the request came with it,
            // so send it; plain "Hey Anu" listens for one.
            openVoiceMode(listen: request == nil)
            if let request {
                inputText = request
                sendMessage()
            }
        }
    }

    private func wireVoice() {
        voiceLoop.attach(speech: speech, tts: tts)
        voiceLoop.cancelAnswer = { orchestrator.cancel() }
        voiceLoop.isThinking = { orchestrator.isThinking }
        voiceLoop.awaitingApproval = { approvals.pending != nil }
        voiceLoop.isRecordingNote = { voiceNotes.phase == .recording }
        voiceLoop.cutRecordingShort = { voiceNotes.appWentToBackground() }
        voiceLoop.shouldSpeak = {
            showVoiceMode || UserDefaults.standard.bool(forKey: SpeechSynthesizer.enabledKey)
        }
    }

    /// Writes the pending voice note down on the device, then runs the turn.
    private func sendVoiceNote() {
        guard !orchestrator.isThinking else { return }
        tts.stop()
        let typed = inputText
        Task {
            await voiceNotes.send(typed: typed, deliver: { info in
                inputText = ""
                await orchestrator.run(voiceNote: info)
            }, say: { orchestrator.messages.append(.system($0)) })
        }
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

            // Attached photos and PDF
            AttachmentTray(composer: composer)

            // A voice note recording or waiting to be sent (ADR-078).
            VoiceNoteComposerStrip(controller: voiceNotes, recorder: voiceNotes.recorder,
                                   onSend: sendVoiceNote)

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
                photoItems: $composer.pickerItems,
                photoLimit: composer.photosLeft,
                hasAttachments: !composer.isEmpty,
                onSend: sendMessage,
                onClear: orchestrator.clearConversation,
                onStop: orchestrator.cancel,
                onMic: { openVoiceMode() },
                onCamera: openCamera,
                onCreateImage: openImageCreation,
                onLiveCamera: liveCameraAction,
                onPDF: { composer.showPDFPicker = true },
                onVoiceNote: { tts.stop(); voiceNotes.startRecording() },
                onAskAboutScreen: screenQuestionAction
            )
        }
        .modifier(LiveTalkPresenceModifier(
            presence: liveTalkPresence, phase: liveTalkPhase, isThinking: orchestrator.isThinking,
            onToggleMute: { voiceLoop.setMuted(!voiceLoop.liveTalk.muted) },
            onStop: closeVoiceMode,
            onEndedInBackground: { note in
                closeVoiceMode()
                orchestrator.messages.append(.system(note))
            }))
        #if os(iOS)
        .modifier(ScreenQuestionModifier(composer: composer, sharedInbox: sharedInbox,
                                         showPicker: $showScreenPicker, text: $inputText))
        #endif
        .fileImporter(isPresented: $composer.showPDFPicker, allowedContentTypes: [.pdf]) { result in
            composer.importPDF(result.map { [$0] })
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
                onToggleListening: {
                    if voiceLoop.liveTalk.active { speech.toggle() } else { voiceLoop.startLiveTalk() }
                },
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
                    composer.addPhotos([data])
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
            wireVoice()
            voiceNotes.importShared()
            consumePendingVoiceStart()
            consumePendingLiveCamera()
            refreshWake()
        }
        // Auto-start the mic when launched via the "Talk to Anu" intent
        // (Action Button / Siri). The intent set a one-shot flag.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                voiceNotes.importShared()
                voiceLoop.resetWake()
                consumePendingVoiceStart()
                consumePendingLiveCamera()
            }
            // Leaving Anu ends a voice note's recording there, kept.
            if phase == .background { voiceNotes.appWentToBackground() }
        }
        .onChange(of: wakeEligible) { _, _ in refreshWake() }
        // Speak the reply as it streams, the first clause early (ADR-129),
        // when spoken replies are on or in voice mode. Talk in, talk back.
        .onChange(of: orchestrator.isThinking) { _, thinking in
            if thinking {
                voiceLoop.turnStarted()
            } else {
                voiceLoop.observe(orchestrator.messages.last, isThinking: false)
                voiceLoop.turnEnded()
            }
        }
        .onChange(of: orchestrator.messages.last?.content) { _, _ in
            voiceLoop.observe(orchestrator.messages.last, isThinking: orchestrator.isThinking)
        }
        .onChange(of: tts.isSpeaking) { _, speaking in
            if speaking { voiceLoop.speechStarted() }
        }
        .onChange(of: voiceLoop.notice) { _, note in
            guard let note else { return }
            orchestrator.messages.append(.system(note))
            voiceLoop.notice = nil
        }
        .onChange(of: voiceNotes.notice) { _, note in
            guard let note else { return }
            orchestrator.messages.append(.system(note))
            voiceNotes.notice = nil
        }
        .onChange(of: speech.transcript) { _, live in
            if speech.isRecording { inputText = live }
        }
        .onChange(of: speech.errorMessage) { _, error in
            if let error { inputText = ""; orchestrator.messages.append(.system(error)) }
        }
        .onChange(of: composer.pickerItems) { _, _ in composer.loadPicked() }
        .onChange(of: sharedInbox.items.count) { _, count in
            if count > 0 { composer.takeShared(sharedInbox.takeAll()) }
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
        // A voice note waiting above the composer goes with what was typed.
        if voiceNotes.phase == .ready { sendVoiceNote(); return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !composer.isEmpty, !orchestrator.isThinking, composer.preparing == 0 else { return }
        tts.stop()   // don't talk over a fresh request
        inputText = ""
        let attachments = composer.take()
        Task {
            await orchestrator.run(userMessage: text, attachments: attachments)
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
    /// "Ask About My Screen" in the composer's menu (iOS only: it picks from Screenshots).
    private var screenQuestionAction: (() -> Void)? {
        #if os(iOS)
        return { showScreenPicker = true }
        #else
        return nil
        #endif
    }

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
