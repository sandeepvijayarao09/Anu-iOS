import AppIntents
import Combine
import Foundation
import SwiftUI
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

// MARK: - Keeping Spotlight in step with chats and memory (A5)
//
// Chats and memory facts are indexed as App Intents entities
// (`CSSearchableIndex.indexAppEntities`, iOS 18 / macOS 15). The indexer
// watches the orchestrator's session list and the memory store, and after a
// short pause re-syncs: shareable items are (re)indexed, and anything that
// stopped being shareable — deleted, made incognito, given its own memory,
// marked private — is removed. The first sync after launch clears each type
// first, so nothing from an earlier run can linger. Workflows keep their own
// `SpotlightIndexer` path.

/// What one sync should do for one entity type. Pure, so it's unit-tested.
struct IndexDiff: Equatable {
    /// Remove every entity of the type before indexing.
    var purgeAll: Bool
    /// IDs to remove (already indexed, no longer wanted).
    var remove: [UUID]
    /// IDs to index or refresh.
    var upsert: [UUID]

    static func plan(previous: Set<UUID>?, desired: [UUID], enabled: Bool) -> IndexDiff {
        guard enabled else { return IndexDiff(purgeAll: true, remove: [], upsert: []) }
        guard let previous else { return IndexDiff(purgeAll: true, remove: [], upsert: desired) }
        let keep = Set(desired)
        let gone = previous.subtracting(keep).sorted { $0.uuidString < $1.uuidString }
        return IndexDiff(purgeAll: false, remove: gone, upsert: desired)
    }
}

/// Where entity writes go. The live one is Spotlight; tests record calls.
@available(iOS 18.0, macOS 15.0, *)
protocol EntityIndexBackend: AnyObject {
    func index<E: IndexedEntity>(_ entities: [E]) async throws
    func delete<E: IndexedEntity>(ids: [E.ID], of type: E.Type) async throws
    func deleteAll<E: IndexedEntity>(of type: E.Type) async throws
}

#if canImport(CoreSpotlight)
@available(iOS 18.0, macOS 15.0, *)
final class SpotlightEntityBackend: EntityIndexBackend {
    private let searchIndex: CSSearchableIndex
    init(searchIndex: CSSearchableIndex = .default()) { self.searchIndex = searchIndex }

    func index<E: IndexedEntity>(_ entities: [E]) async throws {
        guard !entities.isEmpty else { return }
        try await searchIndex.indexAppEntities(entities)
    }
    func delete<E: IndexedEntity>(ids: [E.ID], of type: E.Type) async throws {
        guard !ids.isEmpty else { return }
        try await searchIndex.deleteAppEntities(identifiedBy: ids, ofType: type)
    }
    func deleteAll<E: IndexedEntity>(of type: E.Type) async throws {
        try await searchIndex.deleteAppEntities(ofType: type)
    }
}
#endif

/// The sync engine. Safe to call often; syncs run one at a time.
@available(iOS 18.0, macOS 15.0, *)
@MainActor
final class EntityIndexer {
    private let backend: EntityIndexBackend
    private let defaults: UserDefaults
    /// Also drop Siri donations for removed chats.
    private let forgetDonations: Bool
    private var indexedChats: Set<UUID>?
    private var indexedFacts: Set<UUID>?
    private var running: Task<Void, Never>?

    init(backend: EntityIndexBackend, defaults: UserDefaults = .standard, forgetDonations: Bool = true) {
        self.backend = backend
        self.defaults = defaults
        self.forgetDonations = forgetDonations
    }

    /// Forget what was indexed, so the next sync rebuilds from scratch.
    func invalidate() {
        indexedChats = nil
        indexedFacts = nil
    }

    func sync(sessions: [ChatSession], facts: [MemoryFact]) async {
        let previous = running
        let task = Task { @MainActor in
            await previous?.value
            await self.apply(sessions: sessions, facts: facts)
        }
        running = task
        await task.value
    }

    private func apply(sessions: [ChatSession], facts: [MemoryFact]) async {
        let enabled = AnuIndexPolicy.isEnabled(defaults)
        let chats = AnuIndexPolicy.chats(sessions)
        let memory = AnuIndexPolicy.facts(facts)

        let chatPlan = IndexDiff.plan(previous: indexedChats, desired: chats.map(\.id), enabled: enabled)
        if await apply(chatPlan, entities: chats) {
            indexedChats = enabled ? Set(chats.map(\.id)) : nil
            if forgetDonations, !chatPlan.remove.isEmpty { await Self.forgetChatDonations(chatPlan.remove) }
        }
        let factPlan = IndexDiff.plan(previous: indexedFacts, desired: memory.map(\.id), enabled: enabled)
        if await apply(factPlan, entities: memory) {
            indexedFacts = enabled ? Set(memory.map(\.id)) : nil
        }
    }

    /// True when every write succeeded.
    private func apply<E: IndexedEntity>(_ plan: IndexDiff, entities: [E]) async -> Bool where E.ID == UUID {
        do {
            if plan.purgeAll { try await backend.deleteAll(of: E.self) }
            if !plan.remove.isEmpty { try await backend.delete(ids: plan.remove, of: E.self) }
            let wanted = Set(plan.upsert)
            try await backend.index(entities.filter { wanted.contains($0.id) })
            return true
        } catch {
            return false
        }
    }

    private static func forgetChatDonations(_ ids: [UUID]) async {
        let identifiers = ids.map { EntityIdentifier(for: ChatEntity.self, identifier: $0) }
        for identifier in identifiers {
            _ = try? await IntentDonationManager.shared.deleteDonations(matching: .entityIdentifier(identifier))
        }
    }
}

/// App-facing front door. Not availability-gated, so the app can call it on
/// iOS 17 (where it does nothing: `IndexedEntity` needs iOS 18).
@MainActor
enum AnuSearchIndex {
    private static var subscriptions: Set<AnyCancellable> = []
    private static var engine: AnyObject?

    @available(iOS 18.0, macOS 15.0, *)
    private static var indexer: EntityIndexer {
        if let existing = engine as? EntityIndexer { return existing }
        let made = EntityIndexer(backend: SpotlightEntityBackend())
        engine = made
        return made
    }

    /// Starts watching chats and memory. Idempotent; called once at launch.
    static func start() {
        let orchestrator = AgentOrchestrator.shared, memory = MemoryStore.shared
        guard subscriptions.isEmpty else { return }
        guard #available(iOS 18.0, macOS 15.0, *) else { return }
        // The session list is empty until the orchestrator has loaded it from
        // disk; an empty list is "not loaded yet", never "everything deleted".
        orchestrator.$sessions
            .combineLatest(memory.$facts)
            .filter { sessions, _ in !sessions.isEmpty }
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { sessions, facts in
                Task { @MainActor in
                    await indexer.sync(sessions: sessions, facts: facts)
                    AnuShortcuts.updateAppShortcutParameters()
                }
            }
            .store(in: &subscriptions)
    }

    /// Settings → Search changed: apply it to chats, memory and workflows now.
    static func settingChanged() {
        SpotlightIndexer.shared.reindex(WorkflowManager.shared.workflows)
        guard #available(iOS 18.0, macOS 15.0, *) else { return }
        let sessions = AgentOrchestrator.shared.sessions
        let facts = MemoryStore.shared.facts
        Task { @MainActor in
            await indexer.sync(sessions: sessions, facts: facts)
            AnuShortcuts.updateAppShortcutParameters()
        }
    }

    /// The system lost or wants to rebuild the index (`IndexedEntityQuery`).
    /// Reads from disk, since Anu may have been launched just for this.
    static func reindexFromSystem() async {
        SpotlightIndexer.shared.reindex(WorkflowStore().load())
        guard #available(iOS 18.0, macOS 15.0, *) else { return }
        let loaded = AgentOrchestrator.shared.sessions
        let sessions = loaded.isEmpty ? (SessionStore().loadIndex()?.sessions ?? []) : loaded
        let engine = indexer
        engine.invalidate()
        await engine.sync(sessions: sessions, facts: MemoryStore.shared.facts)
    }

    /// A Spotlight tap on a chat or memory item that arrived as a plain
    /// `CSSearchableItemActionType` activity. Returns false for anything else
    /// (workflow items keep their tap-to-run handler).
    @discardableResult
    static func handleSpotlightTap(_ identifier: String) -> Bool {
        guard #available(iOS 18.0, macOS 15.0, *),
              let entity = EntityIdentifier(activityIdentifier: identifier),
              let id = UUID(uuidString: entity.identifier) else { return false }
        if entity.entityType == ChatEntity.self {
            Task { @MainActor in await AnuRoutes.openChat(id) }
            return true
        }
        if entity.entityType == MemoryFactEntity.self {
            AnuRoutes.request(.memory)
            return true
        }
        return false
    }
}

// MARK: - Settings → Search

/// The switch for all of it. Lives in its own view so SettingsView only gains a line.
struct SearchIndexSettingsSection: View {
    @AppStorage(AnuIndexPolicy.enabledKey) private var enabled = true

    var body: some View {
        Section {
            Toggle(isOn: $enabled) {
                Label("Show in Spotlight & Siri", systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("spotlightIndexingToggle")
            .onChange(of: enabled) { _, _ in AnuSearchIndex.settingChanged() }
        } header: {
            Text("Search")
        } footer: {
            Text("Your chats are searchable on this iPhone: chat titles, memories and workflow names appear in Spotlight and Siri can open them. Incognito chats, chats with their own memory and private memories are never included, and the index stays on this iPhone. Turn this off to remove them all.")
        }
    }
}

// MARK: - The open chat, for Siri (on-screen awareness)

/// Advertises the chat on screen as an `NSUserActivity` tied to its entity
/// (`appEntityIdentifier`, iOS 18.2 / macOS 15.2), so "Siri, summarise this"
/// can reach it. Incognito and isolated chats are never advertised.
struct OpenChatActivityModifier: ViewModifier {
    @ObservedObject private var orchestrator = AgentOrchestrator.shared
    @AppStorage(AnuIndexPolicy.enabledKey) private var enabled = true

    func body(content: Content) -> some View {
        let session = orchestrator.activeSession
        let advertise = enabled && (session.map(AnuIndexPolicy.isShareable) ?? false)
        return content
            .userActivity(ChatEntity.activityType, isActive: advertise) { activity in
                guard let session else { return }
                Self.configure(activity, for: session)
            }
            .onContinueUserActivity(ChatEntity.activityType) { activity in
                guard let raw = activity.userInfo?["chatID"] as? String, let id = UUID(uuidString: raw) else { return }
                Task { @MainActor in await AnuRoutes.openChat(id) }
            }
            .onChange(of: orchestrator.activeSessionID) { _, _ in
                if let session = orchestrator.activeSession, AnuIndexPolicy.isShareable(session), enabled {
                    // Relevance: chats you return to are the ones Siri should suggest.
                    IntentDonationManager.shared.donate(intent: OpenChatIntent(target: ChatEntity(session)))
                }
            }
    }

    static func configure(_ activity: NSUserActivity, for session: ChatSession) {
        activity.title = session.name
        activity.userInfo = ["chatID": session.id.uuidString]
        activity.targetContentIdentifier = "chat:\(session.id.uuidString)"
        // The entity index already makes it searchable; don't add a duplicate.
        activity.isEligibleForSearch = false
        #if os(iOS)
        activity.isEligibleForPrediction = true
        #endif
        activity.persistentIdentifier = session.id.uuidString
        if #available(iOS 18.2, macOS 15.2, *) {
            activity.appEntityIdentifier = EntityIdentifier(for: ChatEntity(session))
        }
    }
}

extension View {
    /// See `OpenChatActivityModifier`.
    func advertisesOpenChat() -> some View { modifier(OpenChatActivityModifier()) }
}
