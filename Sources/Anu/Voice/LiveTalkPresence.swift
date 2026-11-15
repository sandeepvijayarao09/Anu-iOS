import Foundation
import SwiftUI
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import UIKit
#endif

/// Shows live talk outside Anu (ADR-108's iOS form) and keeps it going there:
/// the Live Activity with the current phase, and, while Anu is behind another
/// app, a short background task around each answer being written (listening
/// and speaking are kept alive by the "audio" background mode, since the
/// microphone or speaker is in use; the gap while the answer is written has
/// neither). Ends cleanly: the activity is dismissed at once and the task
/// released whenever live talk stops.
@MainActor
final class LiveTalkPresence: ObservableObject {
    /// Whether the Live Activity is up, so live talk may go on behind other apps.
    @Published private(set) var showing = false
    private(set) var phase: LiveTalkPhase?

    #if canImport(ActivityKit) && os(iOS)
    private var activity: Activity<AnuLiveTalkAttributes>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    /// Whether the user allows Live Activities for Anu.
    var allowed: Bool {
        #if canImport(ActivityKit) && os(iOS)
        return ActivityAuthorizationInfo().areActivitiesEnabled
        #else
        return false
        #endif
    }

    /// Starts the Live Activity (only possible while Anu is on screen).
    func start(phase: LiveTalkPhase = .listening) {
        self.phase = phase
        #if canImport(ActivityKit) && os(iOS)
        guard activity == nil, allowed else { return }
        Self.endStale(except: nil)
        do {
            activity = try Activity.request(
                attributes: AnuLiveTalkAttributes(startedAt: Date()),
                content: ActivityContent(state: AnuLiveTalkAttributes.ContentState(phase: phase), staleDate: nil),
                pushType: nil)
            showing = activity != nil
        } catch {
            activity = nil
            showing = false
        }
        #endif
    }

    func update(_ phase: LiveTalkPhase) {
        guard phase != self.phase else { return }
        self.phase = phase
        #if canImport(ActivityKit) && os(iOS)
        guard let activity else { return }
        let content = ActivityContent(state: AnuLiveTalkAttributes.ContentState(phase: phase), staleDate: nil)
        Task { await activity.update(content) }
        #endif
    }

    /// Ends the Live Activity at once and releases any background time.
    func end() {
        phase = nil
        showing = false
        #if canImport(ActivityKit) && os(iOS)
        endBackgroundTask()
        if let activity {
            self.activity = nil
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        #endif
    }

    /// While Anu is behind another app, writing an answer gets a background
    /// task (iOS gives about 30 seconds); it's released when the answer is done.
    func answerWriting(_ writing: Bool, inBackground: Bool) {
        #if canImport(ActivityKit) && os(iOS)
        if writing && inBackground && showing {
            guard backgroundTask == .invalid else { return }
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Anu live talk answer") { [weak self] in
                Task { @MainActor in self?.endBackgroundTask() }
            }
        } else if !writing {
            endBackgroundTask()
        }
        #endif
    }

    #if canImport(ActivityKit) && os(iOS)
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif

    /// Ends activities left by an earlier run (Anu was closed mid-talk).
    static func endStale(except keep: String? = nil) {
        #if canImport(ActivityKit) && os(iOS)
        for old in Activity<AnuLiveTalkAttributes>.activities where old.id != keep {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        #endif
    }
}

/// Wires live talk's Live Activity to the chat: keeps its phase current,
/// answers its Mute and End buttons, gives an answer being written behind
/// another app its background time, and ends live talk when Anu leaves the
/// screen without a Live Activity to show it (never talking unseen).
struct LiveTalkPresenceModifier: ViewModifier {
    @ObservedObject var presence: LiveTalkPresence
    let phase: LiveTalkPhase?
    let isThinking: Bool
    let onToggleMute: () -> Void
    let onStop: () -> Void
    /// Live talk had to end when Anu left the screen; the note says why.
    let onEndedInBackground: (String) -> Void
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear { if phase == nil { LiveTalkPresence.endStale() } }
            .onChange(of: phase) { _, phase in
                if let phase { presence.update(phase) } else { presence.end() }
            }
            .onChange(of: isThinking) { _, thinking in
                presence.answerWriting(thinking, inBackground: scenePhase != .active)
            }
            .onChange(of: scenePhase) { _, scene in
                guard scene == .background else { return }
                switch LiveTalkBackgroundPolicy.onBackground(liveTalkActive: phase != nil, activityShowing: presence.showing) {
                case .nothing: break
                case .keepGoing: presence.answerWriting(isThinking, inBackground: true)
                case .end(let note): onEndedInBackground(note)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .anuLiveTalkCommand)) { note in
                switch LiveTalkCommand.from(note) {
                case .toggleMute: onToggleMute()
                case .stop: onStop()
                case nil: break
                }
            }
    }
}
