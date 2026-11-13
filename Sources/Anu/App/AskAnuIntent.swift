import AppIntents
import SwiftUI

/// Siri / Shortcuts entry point: "Ask Anu <question>".
/// Opens the app and feeds the question straight into the agent loop,
/// so the model can be invoked from anywhere without finding the app icon.
struct AskAnuIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Anu"
    static let description = IntentDescription("Ask the on-device Anu agent a question.")
    static let openAppWhenRun: Bool = true
    /// `openAppWhenRun` is deprecated from iOS 26; it stays for iOS 17–25.
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

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
/// A `LongRunningIntent` on iOS 27 / macOS 27 (see `ModelIntentSupport.swift`).
struct AskAnuInlineIntent: AnuModelIntent {
    static let title: LocalizedStringResource = "Ask Anu (inline)"
    static let description = IntentDescription("Get a quick spoken answer from the on-device Anu agent without opening the app.")
    static let openAppWhenRun: Bool = false
    /// `openAppWhenRun` is deprecated from iOS 26; it stays for iOS 17–25.
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Question", requestValueDialog: "What should I answer?")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = try await generate(
            system: "You are Anu, a concise on-device assistant. Answer in one or two sentences, plainly.",
            user: question
        )
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension AskAnuInlineIntent: LongRunningIntent {}

/// Japan only (iOS 26.2+): when the user picks Anu as the side-button
/// assistant, pressing and holding the side button runs this. It opens Anu
/// listening, like "Talk to Anu". The schema has no parameters and lists no
/// required entitlement, so it compiles and signs as is; the side button only
/// routes to it once Apple grants the side-button entitlement
/// (reported as `com.apple.developer.side-button-access.allow`), which this
/// project does not request yet.
#if os(iOS)
@available(iOS 26.2, *)
@AppIntent(schema: .assistant.activate)
struct ActivateAnuIntent: AppIntent {
    static let title: LocalizedStringResource = "Activate Anu"
    static let description = IntentDescription("Open Anu and start listening, from the side button.")
    /// The schema requires a foreground-only intent.
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: StartVoiceIntent.pendingVoiceKey)
        return .result()
    }
}
#endif

/// Action-Button / "Talk to Anu" target: opens the app and starts listening
/// immediately (voice-first). Sets a one-shot flag the app consumes when it
/// becomes active, so the mic turns on without an extra tap.
struct StartVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Anu"
    static let description = IntentDescription("Open Anu and start listening right away.")
    static let openAppWhenRun: Bool = true
    /// `openAppWhenRun` is deprecated from iOS 26; it stays for iOS 17–25.
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

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
    /// Hard platform limit: **10 shortcuts per app**. Exceeding it fails the
    /// build in `appintentsmetadataprocessor`, not at compile time, so adding
    /// one here means retiring one (`AppShortcutsTests` checks the count).
    /// Intents not listed remain fully usable in the Shortcuts app — they
    /// only forfeit a pre-registered Siri phrase.
    ///
    /// Re-balanced for value (A7): the calendar, next-event, reminder and
    /// add-event phrases are gone — Siri answers and does those natively, and
    /// the intents stay in Shortcuts. The slots went to what only Anu does:
    /// the live camera, voice notes, opening a chat, and proofreading.
    /// (On the Mac there is no live camera, so it has 9.)
    static let maxShortcuts = 10

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
        #if os(iOS)
        AppShortcut(
            intent: OpenLiveCameraIntent(),
            phrases: [
                "Open live camera in \(.applicationName)",
                "Show \(.applicationName) what I see",
                "\(.applicationName) camera"
            ],
            shortTitle: "Live Camera",
            systemImageName: "camera.viewfinder"
        )
        #endif
        AppShortcut(
            intent: RecordVoiceNoteIntent(),
            phrases: [
                "Record a voice note in \(.applicationName)",
                "Record a voice note for \(.applicationName)",
                "\(.applicationName) voice note"
            ],
            shortTitle: "Voice Note",
            systemImageName: "waveform"
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
            intent: OpenChatIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)",
                "Open my \(.applicationName) chat",
                "Open a chat in \(.applicationName)"
            ],
            shortTitle: "Open Chat",
            systemImageName: "bubble.left.and.bubble.right"
        )
        // No slot for SearchAnuIntent: its `.system.searchInApp` schema is what
        // routes natural "search Anu for …" phrasing, and an `if #available`
        // entry needs the array builder (iOS 17.4+), above this target's 17.0.
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
