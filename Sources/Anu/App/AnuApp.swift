import SwiftUI
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

@main
struct AnuApp: App {
    @StateObject private var orchestrator = AgentOrchestrator.shared
    /// Writing hand-offs from Rewrite with Anu and Anu Keyboard (App Group).
    @StateObject private var writingHandoff = WritingHandoffRunner.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if canImport(UserNotifications)
        // Before launch finishes, so a reminder tap that cold-starts the app
        // still reaches the handler.
        WorkflowNotificationHandler.shared.install()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Drain the App Group inbox when an entry point nudges us
                // (widget button / Siri workflow run, same process).
                .onReceive(NotificationCenter.default.publisher(for: .anuInboxUpdated)) { _ in
                    Task { await orchestrator.drainInbox() }
                }
                #if canImport(CoreSpotlight)
                // A tapped Spotlight result for a saved workflow runs it.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                          let id = UUID(uuidString: raw) else { return }
                    WorkflowManager.shared.enqueueRun(id: id)
                }
                #endif
                // A finished writing hand-off: show it, with Copy.
                .sheet(item: $writingHandoff.latest) { result in
                    WritingHandoffResultView(result: result) { writingHandoff.dismissLatest() }
                }
        }
        // …and whenever the app returns to the foreground (catches Share Sheet
        // hand-offs and anything queued while we were away).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    // Writing hand-offs first: they're short, and an extension waits on them.
                    await writingHandoff.processIfNeeded(orchestrator: orchestrator)
                    await orchestrator.drainInbox()
                }
            } else if phase == .background {
                // Ephemeral ("incognito") sandboxes don't linger after you leave.
                orchestrator.clearActiveIfEphemeral()
            }
        }
        #if os(macOS)
        // A sensible single-column chat window on the Mac (still resizable).
        .defaultSize(width: 480, height: 760)
        #endif
    }
}
