import AppIntents
import SwiftUI

/// Siri / Shortcuts entry point: "Ask Gemma <question>".
/// Opens the app and feeds the question straight into the agent loop,
/// so the model can be invoked from anywhere without finding the app icon.
struct AskGemmaIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Gemma"
    static let description = IntentDescription("Ask the on-device Gemma agent a question.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask Gemma?")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let orchestrator = AgentOrchestrator.shared
        await orchestrator.setup()
        // Fire and return immediately — the answer streams into the chat UI.
        // Blocking here would hit the intent time budget on long generations.
        Task { await orchestrator.run(userMessage: question) }
        return .result()
    }
}

struct GemmaAgentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskGemmaIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question"
            ],
            shortTitle: "Ask Gemma",
            systemImageName: "brain"
        )
        AppShortcut(
            intent: RunWorkflowIntent(),
            phrases: [
                "Run \(\.$workflow) in \(.applicationName)",
                "Run \(\.$workflow) with \(.applicationName)",
                "Run a \(.applicationName) workflow"
            ],
            shortTitle: "Run Workflow",
            systemImageName: "play.circle"
        )
    }
}
