import SwiftUI

struct ContentView: View {
    @EnvironmentObject var orchestrator: AgentOrchestrator
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ChatView()
                .navigationTitle("GemmaAgent")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
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
    }
}
