import SwiftUI

struct ContentView: View {
    @State private var showSettings = false
    @State private var showSessions = false

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
        // A workflow started from Settings → Workflows runs in the chat; close
        // the sheet so the run is visible.
        .onReceive(NotificationCenter.default.publisher(for: .anuShowChat)) { _ in
            showSettings = false
            showSessions = false
        }
        // Siri / Spotlight hand-offs (search, a tapped memory) and the open
        // chat advertised to Siri.
        .sheet(isPresented: $showMemory) {
            NavigationStack { MemoryView() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .anuRouteRequested)) { _ in consumeRoute() }
        .onAppear(perform: consumeRoute)
        .onChange(of: scenePhase) { _, phase in if phase == .active { consumeRoute() } }
        .advertisesOpenChat()
    }

    @State private var showMemory = false
    @Environment(\.scenePhase) private var scenePhase

    private func consumeRoute() {
        switch AnuRoutes.consume() {
        case .memory?:
            showSettings = false
            showSessions = false
            showMemory = true
        case .search?:
            showSettings = false
            showMemory = false
            showSessions = true
        case nil:
            break
        }
    }
}
