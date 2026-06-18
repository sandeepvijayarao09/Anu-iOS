import AppIntents
import SwiftUI

/// Siri / Shortcuts entry point: "Ask Anu <question>".
/// Opens the app and feeds the question straight into the agent loop,
/// so the model can be invoked from anywhere without finding the app icon.
struct AskAnuIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Anu"
    static let description = IntentDescription("Ask the on-device Anu agent a question.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask Anu?")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let orchestrator = AgentOrchestrator.shared
        await orchestrator.setup()
        // Fire and return immediately — the answer streams into the chat UI.
        // Blocking here would hit the intent time budget on long generations.
        Task { await orchestrator.run(userMessage: question) }
        return .result(dialog: "On it — opening Anu to answer that.")
    }
}

/// "Summarize this with Anu" — an inline, **spoken** answer that does NOT open
/// the app. Reuses the bounded headless completion so Siri can read the result
/// aloud (via `ProvidesDialog`) the way the new Siri AI answers conversationally.
struct AskAnuInlineIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Anu (inline)"
    static let description = IntentDescription("Get a quick spoken answer from the on-device Anu agent without opening the app.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Question", requestValueDialog: "What should I answer?")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = await AgentOrchestrator.shared.completeHeadless(
            system: "You are Anu, a concise on-device assistant. Answer in one or two sentences, plainly.",
            user: question
        )
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

/// Action-Button / "Talk to Anu" target: opens the app and starts listening
/// immediately (voice-first). Sets a one-shot flag the app consumes when it
/// becomes active, so the mic turns on without an extra tap.
struct StartVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Anu"
    static let description = IntentDescription("Open Anu and start listening right away.")
    static let openAppWhenRun: Bool = true

    /// UserDefaults flag the app reads on activation to auto-start the mic.
    static let pendingVoiceKey = "pending_voice_start"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        UserDefaults.standard.set(true, forKey: Self.pendingVoiceKey)
        await AgentOrchestrator.shared.setup()
        return .result(dialog: "I'm listening — go ahead.")
    }
}

struct AnuShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskAnuIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question"
            ],
            shortTitle: "Ask Anu",
            systemImageName: "brain"
        )
        AppShortcut(
            intent: AskAnuInlineIntent(),
            phrases: [
                "Quick answer from \(.applicationName)",
                "\(.applicationName) quick answer"
            ],
            shortTitle: "Quick Answer",
            systemImageName: "bolt.fill"
        )
        AppShortcut(
            intent: StartVoiceIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Start talking to \(.applicationName)"
            ],
            shortTitle: "Talk to Anu",
            systemImageName: "mic.fill"
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
        AppShortcut(
            intent: SummarizeTextIntent(),
            phrases: [
                "Summarize with \(.applicationName)",
                "Summarize this with \(.applicationName)"
            ],
            shortTitle: "Summarize",
            systemImageName: "text.append"
        )
        AppShortcut(
            intent: RewriteTextIntent(),
            phrases: [
                "Rewrite with \(.applicationName)",
                "Rewrite this with \(.applicationName)"
            ],
            shortTitle: "Rewrite",
            systemImageName: "pencil.and.outline"
        )
        AppShortcut(
            intent: ProofreadTextIntent(),
            phrases: [
                "Proofread with \(.applicationName)",
                "Proofread this with \(.applicationName)"
            ],
            shortTitle: "Proofread",
            systemImageName: "checkmark.bubble"
        )
    }
}
