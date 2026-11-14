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
        // Finish a "Delete All My Data" before any store loads from disk.
        DataEraser.finishPendingErase()
        #if canImport(UserNotifications)
        // Before launch finishes, so a reminder tap that cold-starts the app
        // still reaches the handler.
        WorkflowNotificationHandler.shared.install()
        #endif
        #if os(iOS)
        // Memory v2 learns while charging; the handler must exist before launch ends.
        MemoryLearner.registerBackgroundTask()
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
                // Shortcuts coming back after the Anu Alarm shortcut ran.
                .onOpenURL { url in ClockShortcut.handle(url) }
                // Chats and memory in Spotlight / Siri, kept in step (A5).
                .task { AnuSearchIndex.start() }
                #if canImport(CoreSpotlight)
                // A tapped Spotlight result for a saved workflow runs it.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
                    // A chat or memory (App Intents entity) opens it instead.
                    if AnuSearchIndex.handleSpotlightTap(raw) { return }
                    guard let id = UUID(uuidString: raw) else { return }
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
                // Facts learned before search by meaning was available catch up.
                Task { await MemoryStore.shared.indexVectors() }
            } else if phase == .background {
                // Ephemeral ("incognito") sandboxes don't linger after you leave.
                orchestrator.clearActiveIfEphemeral()
                // Memory v2: the chat has ended — learn a little, and schedule
                // the rest for when the phone is charging.
                MemoryLearner.shared.appDidEnterBackground()
            }
        }
        #if os(macOS)
        // A sensible single-column chat window on the Mac (still resizable).
        .defaultSize(width: 480, height: 760)
        #endif
    }
}
