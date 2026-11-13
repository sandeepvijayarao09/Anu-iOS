import AppIntents

/// On-device Writing Tools, exposed as App Intents so they work from Siri, the
/// Shortcuts app, and the share/selection menus — matching the new Siri AI's
/// writing capabilities, but running entirely on-device through the same model
/// the chat uses. Each returns its result inline (Siri reads it aloud) without
/// opening the app.
///
/// All three share `AnuModelIntent.generate`, the bounded single-shot
/// generation (`AgentOrchestrator.completeHeadless`) that leaves the chat
/// untouched, with progress. On iOS 27 / macOS 27 they are `LongRunningIntent`s
/// (see `ModelIntentSupport.swift`), so a long text isn't cut off at 30 s.

struct SummarizeTextIntent: AnuModelIntent {
    static let title: LocalizedStringResource = "Summarize Text"
    static let description = IntentDescription("Summarize text with the on-device Anu agent.")
    static let openAppWhenRun = false
    /// `openAppWhenRun` is deprecated from iOS 26; it stays for iOS 17–25.
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Text", requestValueDialog: "What should I summarize?")
    var text: String

    static let systemPrompt = "You are a precise summarizer. Write a concise summary (2–4 sentences) of the user's text. Output only the summary, nothing else."

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = try await generate(system: Self.systemPrompt, user: text)
        return .result(value: result, dialog: IntentDialog(stringLiteral: result))
    }
}

struct RewriteTextIntent: AnuModelIntent {
    static let title: LocalizedStringResource = "Rewrite Text"
    static let description = IntentDescription("Rewrite text to be clearer and more polished, on-device.")
    static let openAppWhenRun = false
    /// `openAppWhenRun` is deprecated from iOS 26; it stays for iOS 17–25.
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Text", requestValueDialog: "What should I rewrite?")
    var text: String

    static let systemPrompt = "You are an expert editor. Rewrite the user's text to be clearer, more concise, and well-phrased while preserving its meaning and tone. Output only the rewritten text."

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = try await generate(system: Self.systemPrompt, user: text)
        return .result(value: result, dialog: IntentDialog(stringLiteral: result))
    }
}

struct ProofreadTextIntent: AnuModelIntent {
    static let title: LocalizedStringResource = "Proofread Text"
    static let description = IntentDescription("Fix grammar and spelling in text, on-device.")
    static let openAppWhenRun = false
    /// `openAppWhenRun` is deprecated from iOS 26; it stays for iOS 17–25.
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Text", requestValueDialog: "What should I proofread?")
    var text: String

    static let systemPrompt = "You are a meticulous proofreader. Correct grammar, spelling, and punctuation in the user's text without changing its meaning or voice. Output only the corrected text."

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = try await generate(system: Self.systemPrompt, user: text)
        return .result(value: result, dialog: IntentDialog(stringLiteral: result))
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension SummarizeTextIntent: LongRunningIntent {}
@available(iOS 27.0, macOS 27.0, *)
extension RewriteTextIntent: LongRunningIntent {}
@available(iOS 27.0, macOS 27.0, *)
extension ProofreadTextIntent: LongRunningIntent {}
