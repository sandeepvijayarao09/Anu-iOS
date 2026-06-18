import Foundation
#if canImport(CoreSpotlight)
import CoreSpotlight
import UniformTypeIdentifiers
#endif

/// Indexes the user's saved Workflows into Spotlight so they're searchable
/// system-wide and surface as proactive Siri Suggestions — the personal-context
/// proactivity the new Siri AI leans on, done with on-device CoreSpotlight only.
/// (App Intents / `AppShortcutsProvider` separately donate the actions to Siri.)
@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()

    /// Domain used for all Anu Spotlight items (lets us replace the set
    /// atomically on each reindex).
    static let domainID = "com.anu.workflows"

    #if canImport(CoreSpotlight)
    private let index: CSSearchableIndex
    init(index: CSSearchableIndex = .default()) { self.index = index }
    #else
    init() {}
    #endif

    /// Replaces the indexed set with the current workflows. Cheap and idempotent;
    /// safe to call on every save.
    func reindex(_ workflows: [Workflow]) {
        #if canImport(CoreSpotlight)
        let items = workflows.map(Self.searchableItem(for:))
        index.deleteSearchableItems(withDomainIdentifiers: [Self.domainID]) { [index] _ in
            guard !items.isEmpty else { return }
            index.indexSearchableItems(items) { _ in }
        }
        #endif
    }

    #if canImport(CoreSpotlight)
    /// Builds a Spotlight item for a workflow. Pure → unit-testable without
    /// touching the live index.
    static func searchableItem(for workflow: Workflow) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: UTType.text)
        attrs.title = workflow.name
        // Keep the saved prompt OUT of the system-wide index — only the name is
        // searchable, so private instructions never leak into Spotlight / Siri.
        attrs.contentDescription = "Anu workflow"
        attrs.keywords = ["Anu", "workflow", "AI"]
        return CSSearchableItem(
            uniqueIdentifier: workflow.id.uuidString,
            domainIdentifier: domainID,
            attributeSet: attrs
        )
    }
    #endif
}
