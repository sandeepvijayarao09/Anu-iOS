import SwiftUI

/// A voice note in the thread: its kind and length, then its words, written
/// down on the device. The recording itself was never kept.
struct VoiceNoteBubble: View {
    let note: VoiceNoteInfo

    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            if let typed = note.typed, !typed.isEmpty {
                Text(typed)
            }
            Label(note.title + (note.interrupted ? " · Stopped early" : ""),
                  systemImage: note.kind == .shared ? "waveform.badge.plus" : "waveform")
                .font(.anuLabel)
                .opacity(0.9)
            Text(note.transcript)
                .italic()
            if let engine = note.engine {
                Text("Written down by \(engine)" + (note.transcribeMillis.map { " in \(Self.seconds($0))" } ?? ""))
                    .font(.anuMeta)
                    .opacity(0.75)
            }
        }
        .padding(.horizontal, Space.comfy)
        .padding(.vertical, Space.base)
        .background(Color.anuAccent)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: Radius.large))
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("voiceNoteBubble")
    }

    private static func seconds(_ millis: Int) -> String {
        String(format: "%.1f s", Double(millis) / 1000)
    }
}

/// Above the composer while a voice note records or waits to be sent:
/// Cancel, the level, the time and Stop; then "Voice note · 0:17" with Remove.
struct VoiceNoteComposerStrip: View {
    @ObservedObject var controller: VoiceNoteController
    @ObservedObject var recorder: VoiceNoteRecorder
    let onSend: () -> Void

    var body: some View {
        Group {
            switch controller.phase {
            case .recording:
                HStack(spacing: Space.base) {
                    Button("Cancel", role: .cancel) { controller.cancelRecording() }
                        .accessibilityIdentifier("voiceNoteCancel")
                    LevelBars(level: recorder.level)
                    Text(VoiceNoteFormat.duration(recorder.seconds))
                        .font(.anuLabel.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { controller.stopRecording() } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                    }
                    .accessibilityIdentifier("voiceNoteStop")
                }
            case .ready, .transcribing:
                HStack(spacing: Space.base) {
                    Image(systemName: "waveform")
                        .foregroundStyle(Color.anuAccent)
                    Text(controller.phase == .transcribing
                         ? "Writing down your voice note…"
                         : controller.pendingTitle ?? "Voice note")
                        .font(.anuLabel)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if controller.phase == .ready {
                        Button("Remove", role: .destructive) { controller.removePending() }
                            .accessibilityIdentifier("voiceNoteRemove")
                        Button(action: onSend) {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                        }
                        .accessibilityLabel("Send voice note")
                        .accessibilityIdentifier("voiceNoteSend")
                    } else {
                        ProgressView()
                    }
                }
            case .idle:
                EmptyView()
            }
        }
        .font(.anuLabel)
        .padding(.horizontal, Space.comfy)
        .padding(.vertical, Space.tight)
        .background(controller.phase == .idle ? Color.clear : Color.anuFill6)
    }
}

private struct LevelBars: View {
    let level: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { index in
                let lit = Double(index) / 8 < level
                Capsule()
                    .fill(lit ? Color.anuAccent : Color.secondary.opacity(0.3))
                    .frame(width: 3, height: 6 + CGFloat(index % 4) * 3)
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }
}

/// Settings → Voice: the foreground wake phrase, honestly labelled.
struct HeyAnuSettingsSection: View {
    @AppStorage(WakeSettings.enabledKey) private var heyAnu = false

    var body: some View {
        Section {
            Toggle("“Hey Anu” while Anu is open", isOn: $heyAnu)
                .accessibilityIdentifier("heyAnuToggle")
            #if os(iOS)
            WakeVoiceSettingsRows()
            #endif
        } header: {
            Text("Wake phrase")
        } footer: {
            Text("Works only while Anu is open and on screen: iOS doesn't let apps listen in the background. While it's on, the microphone stays open and the orange dot shows; what it hears is checked for “Hey Anu” on this device and dropped, never kept or sent. From anywhere else, say “Hey Siri, ask Anu”.")
        }
    }
}
