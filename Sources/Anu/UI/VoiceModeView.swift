import SwiftUI

// MARK: - Voice mode
//
// The hands-free face of Anu (live talk, ADR-129): one big orb, what it's
// doing, a live caption of what it heard and what it's saying, and two
// controls, Mute and End. Everything on this screen is driven by real state
// (mic amplitude, the agent's status, the synthesizer's word cadence), so it
// reads at arm's length. Tapping the orb talks over Anu, or sends now.

struct VoiceModeView: View {
    @ObservedObject var speech: SpeechRecognizer
    @ObservedObject var tts: SpeechSynthesizer
    @ObservedObject var voice: VoiceLoop
    @ObservedObject private var orchestrator = AgentOrchestrator.shared
    @ObservedObject private var approvals = AgentOrchestrator.shared.approvals

    /// When this live talk began: captions show only its turns.
    let since: Date
    let onToggleMute: () -> Void
    let onEnd: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var talk: LiveTalk { voice.liveTalk }

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

    private var phase: LiveTalkPhase? {
        LiveTalkPhase.current(active: talk.active, muted: talk.muted, listening: speech.isRecording,
                              speaking: tts.isSpeaking, thinking: orchestrator.isThinking,
                              awaitingApproval: approvals.pending != nil)
    }

    private var stateLabel: String {
        if speech.errorMessage != nil { return "Voice unavailable" }
        guard let phase else { return "Tap to talk" }
        if talk.paused { return "Paused" }
        if phase == .thinking { return orchestrator.status.displayText }
        return phase.label
    }

    private var heard: String? {
        LiveTalkCaption.heard(live: speech.transcript, isListening: speech.isRecording,
                              messages: orchestrator.messages, since: since)
    }

    private var answer: String? {
        if let problem = speech.errorMessage { return problem }
        // While listening, Anu's last answer gives way to the new request.
        guard !speech.isRecording else { return nil }
        return LiveTalkCaption.answer(messages: orchestrator.messages, since: since)
    }

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                Button(action: voice.tapped) {
                    VoiceOrb(state: orbState, level: orbLevel, size: 260)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(orbLabel)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("voiceModeOrb")

                Text(stateLabel)
                    .font(.anuHeading)
                    .foregroundStyle(speech.errorMessage == nil ? .primary : .secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: stateLabel)
                    .padding(.top, Space.snug)
                    .accessibilityIdentifier("voiceModeCaption")

                captions
                    .padding(.top, Space.base)

                #if DEBUG
                if UserDefaults.standard.bool(forKey: "show_voice_latency"), let sample = voice.lastLatency {
                    Text(sample.summary)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Space.comfy)
                        .accessibilityIdentifier("voiceLatency")
                }
                #endif

                Spacer(minLength: 0)

                controls
                    .padding(.bottom, Space.section)
            }
        }
        // Voice mode covers the chat, so the chat's approval sheet can't show
        // over it: the same sheet is presented from here instead.
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
    }

    /// The user's words above, small; Anu's below, larger, following the
    /// newest words as they're spoken. The space is reserved so the orb
    /// doesn't jump when words arrive.
    private var captions: some View {
        VStack(spacing: Space.snug) {
            Text(heard ?? " ")
                .font(.anuMeta)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("voiceModeHeard")
            ScrollViewReader { proxy in
                ScrollView {
                    Text(answer ?? "")
                        .font(.anuBody)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .id("answer")
                        .accessibilityIdentifier("voiceModeAnswer")
                }
                .scrollIndicators(.hidden)
                .onChange(of: answer) { _, _ in proxy.scrollTo("answer", anchor: .bottom) }
            }
            .frame(height: 120)
        }
        .padding(.horizontal, Space.section)
    }

    /// A wash of the orb's own palette, so the whole screen shifts with state
    /// without competing with the orb for attention.
    private var backdrop: some View {
        let (warm, cool) = orbState.palette
        return RadialGradient(
            colors: [warm.opacity(0.18), cool.opacity(0.10), Color.anuBackground],
            center: .center, startRadius: 0, endRadius: 520
        )
        .background(Color.anuBackground)
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: orbState)
    }

    private var controls: some View {
        HStack(spacing: Space.stage) {
            Button(action: onToggleMute) {
                Image(systemName: talk.muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(talk.muted ? Color.anuBackground : Color.primary)
                    .frame(width: 64, height: 64)
                    .background(talk.muted ? Color.primary : Color.anuFill5, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!talk.active)
            .accessibilityLabel(talk.muted ? "Unmute" : "Mute")
            .accessibilityIdentifier("voiceModeMute")

            Button(action: onEnd) {
                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Color.anuDestructive, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End voice mode")
            .accessibilityIdentifier("voiceModeClose")
        }
    }

    private var orbLabel: String {
        if !talk.active { return "Start talking" }
        if tts.isSpeaking || orchestrator.isThinking { return "Interrupt and talk" }
        return speech.isRecording ? "Send now" : "Start listening"
    }
}
