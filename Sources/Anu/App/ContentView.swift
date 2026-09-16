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
    }
}
