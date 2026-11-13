import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import AppIntents
#endif

// Live talk behind other apps (Android ADR-108), in iOS's form. iOS has no
// overlays, so while live talk is on Anu shows a Live Activity (Lock Screen
// and Dynamic Island) that says what it's doing, "Anu · Listening" and so on,
// with Mute and Stop, and keeps its audio session so the conversation goes on
// while the user is in another app. Live talk never goes on behind another
// app unless that Live Activity is showing, as on Android it never goes on
// without its notification. Compiled into the app and the widget extension
// (which draws the activity).

extension Notification.Name {
    /// Posted in the app's process by the Live Activity's buttons.
    static let anuLiveTalkCommand = Notification.Name("com.anu.liveTalkCommand")
}

/// What live talk is doing, as the Live Activity says it.
enum LiveTalkPhase: String, Codable, Hashable, Sendable {
    case listening, thinking, speaking, waitingForYou, muted

    var label: String {
        switch self {
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .waitingForYou: return "Waiting for you"
        case .muted: return "Muted"
        }
    }

    /// What the user can do, under the phase.
    var hint: String? {
        switch self {
        case .waitingForYou: return "Open Anu to approve or decline"
        case .muted: return "Anu isn't listening"
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .listening: return "waveform"
        case .thinking: return "ellipsis"
        case .speaking: return "speaker.wave.2.fill"
        case .waitingForYou: return "hand.raised.fill"
        case .muted: return "mic.slash.fill"
        }
    }

    /// The phase for the current state, or nil when live talk is off. An
    /// approval wins (Anu can't go on without the user), then mute, then
    /// what the audio is doing.
    static func current(active: Bool, muted: Bool, listening: Bool, speaking: Bool,
                        thinking: Bool, awaitingApproval: Bool) -> LiveTalkPhase? {
        guard active else { return nil }
        if awaitingApproval { return .waitingForYou }
        if speaking { return .speaking }
        if muted { return .muted }
        if listening { return .listening }
        if thinking { return .thinking }
        return .listening
    }
}

/// Commands from the Live Activity's buttons.
enum LiveTalkCommand: String, Sendable {
    case toggleMute, stop

    static let key = "command"

    static func from(_ note: Notification) -> LiveTalkCommand? {
        (note.userInfo?[key] as? String).flatMap(LiveTalkCommand.init(rawValue:))
    }

    func post() {
        NotificationCenter.default.post(name: .anuLiveTalkCommand, object: nil, userInfo: [Self.key: rawValue])
    }
}

/// What to do about live talk when Anu leaves the screen.
enum LiveTalkBackgroundPolicy {
    enum Decision: Equatable {
        case nothing
        case keepGoing
        case end(note: String)
    }

    static let needsLiveActivity = "Live talk ended when you left Anu. Allow Live Activities for Anu in Settings to keep talking in other apps."

    static func onBackground(liveTalkActive: Bool, activityShowing: Bool) -> Decision {
        guard liveTalkActive else { return .nothing }
        return activityShowing ? .keepGoing : .end(note: needsLiveActivity)
    }
}

#if canImport(ActivityKit) && os(iOS)
/// The Live Activity's data. Only the phase is shown: never what was said,
/// since the Lock Screen is visible to anyone holding the phone.
struct AnuLiveTalkAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var phase: LiveTalkPhase
    }

    var startedAt: Date
}

/// Mute (or unmute) from the Live Activity. Runs in Anu's process.
struct ToggleLiveTalkMuteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mute or Unmute Anu"
    static let description = IntentDescription("Stops or resumes Anu listening during live talk.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await MainActor.run { LiveTalkCommand.toggleMute.post() }
        return .result()
    }
}

/// End live talk from the Live Activity. Runs in Anu's process.
struct StopLiveTalkIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End Live Talk"
    static let description = IntentDescription("Ends live talk with Anu.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await MainActor.run { LiveTalkCommand.stop.post() }
        return .result()
    }
}
#endif
