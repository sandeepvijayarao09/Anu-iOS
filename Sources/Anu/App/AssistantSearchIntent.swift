import AppIntents
import Foundation

// MARK: - Apple Intelligence app schema: search in app (A4)
//
// Adopting a schema is what lets Siri route *natural* phrasing to an app —
// with plain `AppShortcut` phrases the user has to say something close to the
// registered wording.
//
// One schema fits an assistant like Anu: search. Until iOS 26 it was
// `@AssistantIntent(schema: .system.search)`; in the 27 SDK both the macro and
// the schema are deprecated ("renamed to AppIntent", "Use
// .system.searchInApp instead"), so this is now
// `@AppIntent(schema: .system.searchInApp)` (`SystemSearchInAppIntent`:
// one `criteria: StringSearchCriteria` parameter, opens the app). The schema
// only exists from iOS 27 / macOS 27; on older systems the intent is simply
// absent and the plain App Shortcuts still work.
//
// Why not the obvious alternative: the `.mail.*` family is create / update /
// save / send draft, reply, forward, archive, delete — every one a *mutation
// on a mailbox the app owns*. There is no search-or-read mail schema. They
// exist so a mail client can hand Siri its own mail, which Anu isn't.

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .system.searchInApp)
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
        // this opens Anu's chat list with the term applied.
        SearchAnuIntentKeys.stage(criteria.term)
        return .result()
    }
}

/// Kept outside the intent so the consumer doesn't have to be gated on
/// iOS 27 just to read a key name.
enum SearchAnuIntentKeys {
    /// Read once by `SessionListView` on appear, then cleared — the same
    /// one-shot hand-off `StartVoiceIntent` uses for the mic.
    static let pendingSearch = "anu.pendingSearchTerm"

    /// Stages a term and asks the UI to open the chat list, where
    /// `SessionListView` applies it.
    static func stage(_ term: String, defaults: UserDefaults = .standard) {
        defaults.set(term, forKey: pendingSearch)
        AnuRoutes.request(.search, defaults: defaults)
    }
}
