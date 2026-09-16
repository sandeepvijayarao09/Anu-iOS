import SwiftUI

// MARK: - Voice mode
//
// The hands-free face of Anu: one big orb, the words currently in play, and
// nothing else. Everything on this screen is driven by real state — mic
// amplitude, the agent's status, the synthesizer's word cadence — so the
// screen is readable at arm's length without reading any text at all.

struct VoiceModeView: View {
    @ObservedObject var speech: SpeechRecognizer
    @ObservedObject var tts: SpeechSynthesizer
    @ObservedObject private var orchestrator = AgentOrchestrator.shared

    /// Toggles listening. Owned by the chat so the transcript still routes
    /// through the existing send path.
    let onToggleListening: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    private var caption: String {
        if speech.errorMessage != nil { return "Voice unavailable" }
        switch orbState {
        case .listening: return "Listening"
        case .thinking: return orchestrator.status.displayText
        case .speaking: return "Speaking"
        case .idle: return "Tap to talk"
        }
    }

    /// What to show under the orb: your words while you speak, Anu's while it
    /// answers. Only one of the two is ever relevant.
    private var subtitle: String? {
        // A mic that never delivered audio outranks anything else here —
        // otherwise the screen just sits at "Tap to talk" saying nothing.
        if let problem = speech.errorMessage { return problem }
        if speech.isRecording {
            let live = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            return live.isEmpty ? nil : live
        }
        guard let last = orchestrator.messages.last, last.role == .assistant else { return nil }
        let text = last.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                Button(action: onToggleListening) {
                    VoiceOrb(state: orbState, level: orbLevel, size: 280)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(speech.isRecording ? "Stop listening" : "Start listening")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("voiceModeOrb")

                Text(caption)
                    .font(.anuHeading)
                    .foregroundStyle(speech.errorMessage == nil ? .primary : .secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: caption)
                    .padding(.top, Space.snug)
                    .accessibilityIdentifier("voiceModeCaption")

                // Reserve the space so the orb doesn't jump when words arrive.
                ScrollView {
                    Text(subtitle ?? "")
                        .font(.anuBody)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, Space.section)
                }
                .frame(height: 132)
                .scrollIndicators(.hidden)
                .padding(.top, Space.base)

                Spacer(minLength: 0)

                controls
                    .padding(.bottom, Space.section)
            }
        }
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
            Button(action: onDismiss) {
                Label("Done", systemImage: "chevron.down")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .background(Color.anuFill5, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close voice mode")
            .accessibilityIdentifier("voiceModeClose")

            Button {
                if orchestrator.isThinking {
                    orchestrator.cancel()
                } else if tts.isSpeaking {
                    tts.stop()
                } else {
                    onToggleListening()
                }
            } label: {
                Image(systemName: stopOrMicIcon)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .background(Color.anuFill5, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(stopOrMicLabel)
            .accessibilityIdentifier("voiceModeAction")
        }
    }

    private var stopOrMicIcon: String {
        if orchestrator.isThinking || tts.isSpeaking { return "stop.fill" }
        return speech.isRecording ? "mic.slash.fill" : "mic.fill"
    }

    private var stopOrMicLabel: String {
        if orchestrator.isThinking { return "Stop generating" }
        if tts.isSpeaking { return "Stop speaking" }
        return speech.isRecording ? "Stop listening" : "Start listening"
    }
}
