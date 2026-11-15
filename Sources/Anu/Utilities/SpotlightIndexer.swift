import Foundation
import AppIntents
#if canImport(CoreSpotlight)
import CoreSpotlight
import UniformTypeIdentifiers
#endif

/// Indexes the user's saved Workflows into Spotlight so they're searchable
/// system-wide and surface as proactive Siri Suggestions — the personal-context
/// proactivity the new Siri AI leans on, done with on-device CoreSpotlight only.
/// (App Intents / `AppShortcutsProvider` separately donate the actions to Siri.)
///
/// On iOS 18 / macOS 15 each item is also linked to its `WorkflowEntity`
/// (`associateAppEntity`), so Siri knows it's a workflow it can run. Chats and
/// memory are indexed as entities by `AnuSearchIndex`. Everything respects
/// Settings → Search (`AnuIndexPolicy.isEnabled`).
@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()

    /// Domain used for all Anu Spotlight items (lets us replace the set
    /// atomically on each reindex).
    static let domainID = "com.anu.workflows"

    private let defaults: UserDefaults
    /// The last run time seen per workflow, so a new run is donated once.
    private var lastRuns: [UUID: Date]?

    #if canImport(CoreSpotlight)
    private let index: CSSearchableIndex
    init(index: CSSearchableIndex = .default(), defaults: UserDefaults = .standard) {
        self.index = index
        self.defaults = defaults
    }
    #else
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    #endif

    /// Replaces the indexed set with the current workflows. Cheap and idempotent;
    /// safe to call on every save. With search turned off it only removes.
    func reindex(_ workflows: [Workflow]) {
        let enabled = AnuIndexPolicy.isEnabled(defaults)
        donateNewRuns(workflows, enabled: enabled)
        #if canImport(CoreSpotlight)
        let items = enabled ? workflows.map(Self.searchableItem(for:)) : []
        index.deleteSearchableItems(withDomainIdentifiers: [Self.domainID]) { [index] _ in
            guard !items.isEmpty else { return }
            index.indexSearchableItems(items) { _ in }
        }
        #endif
    }

    /// Relevance: a workflow that just ran (from anywhere) is donated, so Siri
    /// learns which ones you use and when.
    private func donateNewRuns(_ workflows: [Workflow], enabled: Bool) {
        let current = Dictionary(workflows.compactMap { w in w.lastRunAt.map { (w.id, $0) } },
                                 uniquingKeysWith: { a, _ in a })
        defer { lastRuns = current }
        guard enabled, let previous = lastRuns else { return }
        for workflow in workflows {
            guard let ran = workflow.lastRunAt, previous[workflow.id].map({ ran > $0 }) ?? true else { continue }
            IntentDonationManager.shared.donate(intent: RunWorkflowIntent(workflow: WorkflowEntity(workflow)))
        }
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
        if #available(iOS 18.0, macOS 15.0, *) {
            attrs.associateAppEntity(WorkflowEntity(workflow))
        }
        return CSSearchableItem(
            uniqueIdentifier: workflow.id.uuidString,
            domainIdentifier: domainID,
            attributeSet: attrs
        )
    }
    #endif
}
