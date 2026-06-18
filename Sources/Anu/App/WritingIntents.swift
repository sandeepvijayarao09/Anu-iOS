import AppIntents

/// On-device Writing Tools, exposed as App Intents so they work from Siri, the
/// Shortcuts app, and the share/selection menus — matching the new Siri AI's
/// writing capabilities, but running entirely on-device through the same model
/// the chat uses. Each returns its result inline (Siri reads it aloud) without
/// opening the app.
///
/// All three share `AgentOrchestrator.completeHeadless`, the bounded single-shot
/// generation that leaves the chat untouched.

struct SummarizeTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Text"
    static let description = IntentDescription("Summarize text with the on-device Anu agent.")
    static let openAppWhenRun = false

    @Parameter(title: "Text", requestValueDialog: "What should I summarize?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = await AgentOrchestrator.shared.completeHeadless(
            system: "You are a precise summarizer. Write a concise summary (2–4 sentences) of the user's text. Output only the summary, nothing else.",
            user: text
        )
        return .result(value: result, dialog: IntentDialog(stringLiteral: result))
    }
}

struct RewriteTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Rewrite Text"
    static let description = IntentDescription("Rewrite text to be clearer and more polished, on-device.")
    static let openAppWhenRun = false

    @Parameter(title: "Text", requestValueDialog: "What should I rewrite?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = await AgentOrchestrator.shared.completeHeadless(
            system: "You are an expert editor. Rewrite the user's text to be clearer, more concise, and well-phrased while preserving its meaning and tone. Output only the rewritten text.",
            user: text
        )
        return .result(value: result, dialog: IntentDialog(stringLiteral: result))
    }
}

struct ProofreadTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Proofread Text"
    static let description = IntentDescription("Fix grammar and spelling in text, on-device.")
    static let openAppWhenRun = false

    @Parameter(title: "Text", requestValueDialog: "What should I proofread?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = await AgentOrchestrator.shared.completeHeadless(
            system: "You are a meticulous proofreader. Correct grammar, spelling, and punctuation in the user's text without changing its meaning or voice. Output only the corrected text.",
            user: text
        )
        return .result(value: result, dialog: IntentDialog(stringLiteral: result))
    }
}
