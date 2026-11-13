import AppIntents

// MARK: - Apple Intelligence assistant schema
//
// Adopting a schema is what lets Siri route *natural* phrasing to an app —
// with plain `AppShortcut` phrases the user has to say something close to the
// registered wording.
//
// Of the schemas the iOS 26 SDK actually ships, exactly one fits an assistant
// like Anu: `.system.search` (`ShowInAppSearchResultsIntent`). Worth recording
// why the obvious candidate doesn't:
//
//   The `.mail.*` family is createDraft / updateDraft / saveDraft /
//   deleteDraft / sendDraft / forwardMail / replyMail / archiveMail /
//   deleteMail / updateMail. Every one is a *mutation on a mailbox the app
//   owns* — there is no search-or-read mail schema at all. They exist so that
//   a mail client can hand Siri control of its own mail, which is not what
//   Anu is. Adopting them would mean claiming to be a mail app.
//
// So: search is the schema, and the Gemma/Gemini answer path stays behind
// Anu's own intents.

@available(iOS 18.2, *)
// `@AppIntent(schema:)` is the iOS 27 SDK's name for `@AssistantIntent`
// (same macro, iOS 18+). `.search` is deprecated from iOS 27 in favour of
// `.system.searchInApp`, which only exists on 27; it stays until Anu's
// minimum OS reaches 27.
@AppIntent(schema: .system.search)
struct SearchAnuIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Search Anu"
    static let description = IntentDescription(
        "Search your Anu conversations and memory.")

    /// The scopes Siri may offer. Anu's searchable content is its saved
    /// conversations and the memory notes answers are grounded in.
    static let searchScopes: [StringSearchScope] = [.general]

    @Parameter(title: "Search term")
    var criteria: StringSearchCriteria

    @MainActor
    func perform() async throws -> some IntentResult {
        // A schema search hands the user off to the app showing results, so
        // this opens Anu with the term staged rather than answering inline.
        UserDefaults.standard.set(criteria.term, forKey: SearchAnuIntentKeys.pendingSearch)
        return .result()
    }
}

/// Kept outside the intent so the consumer doesn't have to be gated on
/// iOS 18.2 just to read a key name.
enum SearchAnuIntentKeys {
    /// Read once by `SessionListView` on appear, then cleared — the same
    /// one-shot hand-off `StartVoiceIntent` uses for the mic.
    static let pendingSearch = "anu.pendingSearchTerm"
}
