import SwiftUI

@main
struct AnuApp: App {
    @StateObject private var orchestrator = AgentOrchestrator.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Drain the App Group inbox when an entry point nudges us
                // (widget button / Siri workflow run, same process).
                .onReceive(NotificationCenter.default.publisher(for: .anuInboxUpdated)) { _ in
                    Task { await orchestrator.drainInbox() }
                }
        }
        // …and whenever the app returns to the foreground (catches Share Sheet
        // hand-offs and anything queued while we were away).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await orchestrator.drainInbox() }
            } else if phase == .background {
                // Ephemeral ("incognito") sandboxes don't linger after you leave.
                orchestrator.clearActiveIfEphemeral()
            }
        }
    }
}
