import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Live talk on the Lock Screen and in the Dynamic Island (ADR-108's iOS
/// form): "Anu · Listening" (or Thinking, Speaking, Waiting for you, Muted)
/// with Mute and End. A tap anywhere else opens Anu. Only the phase is shown,
/// never what was said.
struct LiveTalkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AnuLiveTalkAttributes.self) { context in
            LiveTalkLockScreenView(phase: context.state.phase)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let phase = context.state.phase
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Anu", systemImage: "brain").font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: phase.symbol).foregroundStyle(.blue)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(phase.label).font(.subheadline.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LiveTalkButtons(phase: phase)
                }
            } compactLeading: {
                Image(systemName: "brain").foregroundStyle(.blue)
            } compactTrailing: {
                Image(systemName: phase.symbol)
            } minimal: {
                Image(systemName: phase.symbol).foregroundStyle(.blue)
            }
        }
    }
}

private struct LiveTalkLockScreenView: View {
    let phase: LiveTalkPhase

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: phase.symbol).foregroundStyle(.blue)
                Text("Anu · \(phase.label)").font(.headline).foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            if let hint = phase.hint {
                Text(hint).font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            LiveTalkButtons(phase: phase)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct LiveTalkButtons: View {
    let phase: LiveTalkPhase

    var body: some View {
        HStack(spacing: 10) {
            Button(intent: ToggleLiveTalkMuteIntent()) {
                Label(phase == .muted ? "Unmute" : "Mute",
                      systemImage: phase == .muted ? "mic.fill" : "mic.slash.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(.gray)
            Button(intent: StopLiveTalkIntent()) {
                Label("End", systemImage: "xmark").frame(maxWidth: .infinity)
            }
            .tint(.red)
        }
        .buttonStyle(.borderedProminent)
        .font(.caption.weight(.semibold))
    }
}
