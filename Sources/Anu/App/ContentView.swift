import SwiftUI

struct ContentView: View {
    @State private var showSettings = false
    @State private var showSessions = false
    /// The Daily Brief, from its morning notification or "Brief me".
    @State private var showBrief = false
    @ObservedObject private var briefRouter = DailyBriefRouter.shared

    var body: some View {
        NavigationStack {
            ChatView(onOpenSettings: { showSettings = true })
                // Stable app-identity title (the active chat's name shows in the
                // chat-list drawer). Keeping it constant also anchors UI tests.
                .navigationTitle("Anu")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .anuLeading) {
                        Button {
                            showSessions = true
                        } label: {
                            Image(systemName: "bubble.left.and.bubble.right")
                        }
                        .accessibilityLabel("Chats")
                        .accessibilityIdentifier("sessionListButton")
                    }
                    ToolbarItem(placement: .anuTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gear")
                        }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("settingsButton")
                    }
                }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showSessions) {
            SessionListView()
        }
        .sheet(isPresented: $showBrief) {
            NavigationStack { DailyBriefView(onClose: { showBrief = false }) }
        }
        .onChange(of: briefRouter.pending) { _, pending in if pending { openBrief() } }
        .onAppear { if briefRouter.pending { openBrief() } }
        // A workflow started from Settings → Workflows runs in the chat; close
        // the sheet so the run is visible.
        .onReceive(NotificationCenter.default.publisher(for: .anuShowChat)) { _ in
            showSettings = false
            showSessions = false
        }
    }

    /// Closes any other sheet first: only one can show at a time.
    private func openBrief() {
        briefRouter.pending = false
        let waits = showSettings || showSessions
        showSettings = false
        showSessions = false
        DispatchQueue.main.asyncAfter(deadline: .now() + (waits ? 0.6 : 0)) { showBrief = true }
    }
}
