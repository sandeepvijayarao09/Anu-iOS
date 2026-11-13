import SwiftUI

#if os(iOS)
/// Settings › Wake phrase: teach "Hey Anu" the user's voice, or forget it
/// (Android ADR-121's "Your voice").
struct WakeVoiceSettingsRows: View {
    @ObservedObject private var store = WakeVoiceStore.shared
    @State private var teaching = false
    @State private var confirmForget = false

    var body: some View {
        Button(store.hasVoice ? "Teach Anu your voice again" : "Teach Anu your voice") { teaching = true }
            .accessibilityIdentifier("teachWakeVoice")
        if store.hasVoice {
            Button("Forget my voice", role: .destructive) { confirmForget = true }
                .accessibilityIdentifier("forgetWakeVoice")
                .confirmationDialog("Forget your voice?", isPresented: $confirmForget, titleVisibility: .visible) {
                    Button("Forget my voice", role: .destructive) { store.delete() }
                } message: {
                    Text("“Hey Anu” goes back to on-device speech recognition until you teach it again.")
                }
        }
        Text(store.hasVoice
             ? "“Hey Anu” listens for your own voice, from four samples kept encrypted on this iPhone. They never leave it."
             : "Four samples of you saying “Hey Anu” let it listen for your voice instead of transcribing speech.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .sheet(isPresented: $teaching) { WakeVoiceEnrollmentSheet() }
    }
}

/// Records four samples one at a time, each until the user stops talking,
/// says why one wasn't kept, then saves the voice.
struct WakeVoiceEnrollmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = WakeEnrollmentModel()
    @State private var recorder = WakeSampleRecorder()

    var body: some View {
        NavigationStack {
            VStack(spacing: Space.loose) {
                Spacer()
                Image(systemName: model.phase == .done ? "checkmark.circle.fill" : "waveform")
                    .font(.system(size: 56))
                    .foregroundStyle(model.phase == .recording ? Color.anuAccent : Color.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if model.phase == .recording {
                    ProgressView(value: Double(model.level))
                        .frame(maxWidth: 200)
                        .accessibilityLabel("Loudness")
                }
                if let note = model.note {
                    Text(note)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("wakeVoiceNote")
                }
                HStack(spacing: Space.snug) {
                    ForEach(0..<model.total, id: \.self) { index in
                        Circle()
                            .fill(index < model.kept ? Color.anuAccent : Color.secondary.opacity(0.3))
                            .frame(width: 10, height: 10)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("\(model.kept) of \(model.total) samples")
                Spacer()
                actionButton
            }
            .padding(Space.comfy)
            .navigationTitle("Teach Anu your voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.phase == .done ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
        .onAppear { WakeVoiceStore.shared.isEnrolling = true }
        .onDisappear {
            recorder.cancel(model)
            WakeVoiceStore.shared.isEnrolling = false
        }
    }

    private var title: String {
        switch model.phase {
        case .done: return "Anu knows your voice"
        case .recording: return "Say “Hey Anu”"
        case .checking: return "Checking…"
        case .ready:
            return model.kept == 0
                ? "Say “Hey Anu” as you usually would, four times"
                : "Sample \(model.kept + 1) of \(model.total)"
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch model.phase {
        case .done:
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        case .recording:
            Button("Stop") { recorder.stop(model) }
                .buttonStyle(.bordered)
        case .checking:
            ProgressView()
        case .ready:
            Button(model.kept == 0 ? "Record the first sample" : "Record the next sample") {
                Task { await recorder.record(into: model) }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("recordWakeSample")
        }
    }
}
#endif
