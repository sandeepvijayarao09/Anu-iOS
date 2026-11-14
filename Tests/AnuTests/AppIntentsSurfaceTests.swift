import XCTest
import AppIntents
@testable import Anu

/// A4–A8: the Siri / Spotlight surface. Everything here is pure or runs
/// against a recording index, so no Spotlight, Siri or model is touched.
@MainActor
final class AppIntentsSurfaceTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppIntentsSurfaceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: A7 — App Shortcuts cap

    func testAppShortcutsStayWithinTheCap() {
        // appintentsmetadataprocessor fails the build above 10. The provider
        // has no runtime branches on iOS, so this is the static count too.
        let count = AnuShortcuts.appShortcuts.count
        XCTAssertLessThanOrEqual(count, AnuShortcuts.maxShortcuts)
        XCTAssertEqual(AnuShortcuts.maxShortcuts, 10)
        #if os(iOS)
        XCTAssertEqual(count, 10, "the re-balanced set uses every slot")
        #endif
    }

    // MARK: A5 — privacy policy

    func testIncognitoAndIsolatedChatsAreNeverShareable() {
        let normal = ChatSession(name: "Trip planning")
        let incognito = ChatSession(name: "Secret", ephemeral: true)
        let isolated = ChatSession(name: "Own memory", memoryScope: .isolated)
        let chats = AnuIndexPolicy.chats([normal, incognito, isolated])
        XCTAssertEqual(chats.map(\.id), [normal.id])
        XCTAssertEqual(chats.first?.name, "Trip planning")
    }

    func testPrivateAndSupersededFactsAreNeverShareable() {
        var visible = MemoryFact(content: "Likes window seats")
        visible.section = .preferences
        var secret = MemoryFact(content: "Blood type O negative")
        secret.sensitive = true
        var old = MemoryFact(content: "Lives in Leeds")
        old.status = .superseded
        let facts = AnuIndexPolicy.facts([visible, secret, old])
        XCTAssertEqual(facts.map(\.id), [visible.id])
        XCTAssertEqual(facts.first?.text, "Likes window seats")
    }

    func testSearchSwitchDefaultsOn() {
        XCTAssertTrue(AnuIndexPolicy.isEnabled(defaults))
        defaults.set(false, forKey: AnuIndexPolicy.enabledKey)
        XCTAssertFalse(AnuIndexPolicy.isEnabled(defaults))
    }

    // MARK: A5 — index diff

    func testPlanFirstSyncPurgesThenIndexes() {
        let a = UUID(), b = UUID()
        let plan = IndexDiff.plan(previous: nil, desired: [a, b], enabled: true)
        XCTAssertTrue(plan.purgeAll)
        XCTAssertEqual(plan.upsert, [a, b])
        XCTAssertTrue(plan.remove.isEmpty)
    }

    func testPlanRemovesWhatIsGone() {
        let a = UUID(), b = UUID()
        let plan = IndexDiff.plan(previous: [a, b], desired: [a], enabled: true)
        XCTAssertFalse(plan.purgeAll)
        XCTAssertEqual(plan.remove, [b])
        XCTAssertEqual(plan.upsert, [a])
    }

    func testPlanDisabledRemovesEverything() {
        let plan = IndexDiff.plan(previous: [UUID()], desired: [UUID()], enabled: false)
        XCTAssertEqual(plan, IndexDiff(purgeAll: true, remove: [], upsert: []))
    }

    // MARK: A5 — sync engine against a recording index

    func testIndexerIndexesOnlyShareableAndRemovesDeleted() async throws {
        guard #available(iOS 18.0, macOS 15.0, *) else { throw XCTSkip("IndexedEntity needs iOS 18") }
        let backend = RecordingIndex()
        let indexer = EntityIndexer(backend: backend, defaults: defaults, forgetDonations: false)
        let keep = ChatSession(name: "Keep")
        let gone = ChatSession(name: "Will be deleted")
        let incognito = ChatSession(name: "Incognito", ephemeral: true)
        var secret = MemoryFact(content: "PIN hint")
        secret.sensitive = true
        let fact = MemoryFact(content: "Prefers tea")

        await indexer.sync(sessions: [keep, gone, incognito], facts: [fact, secret])
        XCTAssertEqual(backend.ids(ChatEntity.self), [keep.id, gone.id])
        XCTAssertEqual(backend.ids(MemoryFactEntity.self), [fact.id])
        XCTAssertEqual(backend.purges.count, 2, "first sync clears each type once")

        // Deleted chat, and the kept one is made incognito afterwards.
        var nowIncognito = keep
        nowIncognito.ephemeral = true
        await indexer.sync(sessions: [nowIncognito], facts: [])
        XCTAssertEqual(backend.ids(ChatEntity.self), [])
        XCTAssertEqual(backend.ids(MemoryFactEntity.self), [])
        XCTAssertEqual(backend.purges.count, 2, "later syncs remove by ID")
    }

    func testIndexerWithSearchOffRemovesEverything() async throws {
        guard #available(iOS 18.0, macOS 15.0, *) else { throw XCTSkip("IndexedEntity needs iOS 18") }
        let backend = RecordingIndex()
        let indexer = EntityIndexer(backend: backend, defaults: defaults, forgetDonations: false)
        let chat = ChatSession(name: "Hello")
        await indexer.sync(sessions: [chat], facts: [MemoryFact(content: "x")])
        XCTAssertEqual(backend.ids(ChatEntity.self), [chat.id])

        defaults.set(false, forKey: AnuIndexPolicy.enabledKey)
        await indexer.sync(sessions: [chat], facts: [MemoryFact(content: "x")])
        XCTAssertEqual(backend.ids(ChatEntity.self), [])
        XCTAssertEqual(backend.ids(MemoryFactEntity.self), [])
    }

    func testEntityAttributesCarryTitlesOnly() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else { throw XCTSkip("IndexedEntity needs iOS 18") }
        let chat = ChatEntity(ChatSession(name: "Passport renewal"))
        XCTAssertEqual(chat.attributeSet.title, "Passport renewal")
        XCTAssertEqual(chat.attributeSet.contentDescription, "Anu chat")
        let workflow = WorkflowEntity(Workflow(name: "Brief", prompt: "SECRET PROMPT"))
        XCTAssertEqual(workflow.attributeSet.title, "Brief")
        XCTAssertNotEqual(workflow.attributeSet.contentDescription, "SECRET PROMPT")
    }

    // MARK: A5 — queries

    func testChatQueryHidesPrivateChatsAndHonoursTheSwitch() async throws {
        let normal = ChatSession(name: "Groceries", updatedAt: Date(timeIntervalSince1970: 10))
        let newer = ChatSession(name: "Grocery list v2", updatedAt: Date(timeIntervalSince1970: 20))
        let incognito = ChatSession(name: "Grocery secret", ephemeral: true)
        let suite = defaults!
        let query = ChatEntityQuery(sessions: { [normal, newer, incognito] }, defaults: { suite })

        let byID = try await query.entities(for: [normal.id, incognito.id])
        XCTAssertEqual(byID.map(\.id), [normal.id])
        let suggested = try await query.suggestedEntities()
        XCTAssertEqual(suggested.map(\.id), [newer.id, normal.id], "newest first, no incognito")
        let matched = try await query.entities(matching: "list")
        XCTAssertEqual(matched.map(\.id), [newer.id])

        suite.set(false, forKey: AnuIndexPolicy.enabledKey)
        let off = try await query.suggestedEntities()
        XCTAssertTrue(off.isEmpty)
        // A shortcut that already names a chat keeps working.
        let stillByID = try await query.entities(for: [normal.id])
        XCTAssertEqual(stillByID.count, 1)
    }

    func testTranscriptKeepsOnlyUserAndAnuTurns() {
        let messages: [AgentMessage] = [.user("Plan a trip"), .system("note"), .assistant("Sure — where to?")]
        let text = ChatEntity.transcript(name: "Trip", messages: messages)
        XCTAssertEqual(text, "Trip\n\nYou: Plan a trip\n\nAnu: Sure — where to?")
    }

    // MARK: Routes and hand-offs

    func testRoutesAreOneShot() {
        AnuRoutes.request(.memory, defaults: defaults)
        XCTAssertEqual(AnuRoutes.consume(defaults), .memory)
        XCTAssertNil(AnuRoutes.consume(defaults))
    }

    func testSearchStagesTermAndOpensChatList() {
        SearchAnuIntentKeys.stage("passport", defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: SearchAnuIntentKeys.pendingSearch), "passport")
        XCTAssertEqual(AnuRoutes.consume(defaults), .search)
    }

    func testVoiceNoteFlagIsOneShot() {
        defaults.set(true, forKey: RecordVoiceNoteIntent.pendingKey)
        XCTAssertTrue(RecordVoiceNoteIntent.consumePending(defaults))
        XCTAssertFalse(RecordVoiceNoteIntent.consumePending(defaults))
    }

    // MARK: A6 — long-running budget

    func testLongRunningBudget() {
        XCTAssertEqual(ModelIntentBudget.timeout(longRunning: false), .seconds(25))
        XCTAssertEqual(ModelIntentBudget.timeout(longRunning: true), .seconds(180))
        XCTAssertEqual(ModelIntentBudget.maxTokens(256, longRunning: false), 256)
        XCTAssertEqual(ModelIntentBudget.maxTokens(256, longRunning: true), 512)
        #if compiler(>=6.4)  // iOS 27 SDK APIs (Xcode 27)
        if #available(iOS 27.0, macOS 27.0, *) {
            XCTAssertTrue(ModelIntentBudget.longRunningAvailable)
            XCTAssertTrue((SummarizeTextIntent() as Any) is any LongRunningIntent)
            XCTAssertTrue((AskAnuInlineIntent() as Any) is any LongRunningIntent)
        }
        #endif
    }

    func testHeadlessCompletionReportsTokenProgress() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ais-\(UUID().uuidString)", isDirectory: true)
        let orch = AgentOrchestrator(model: QueuedMockModel(["A short answer."]), sessionsDirectory: dir)
        let counter = TokenCounter()
        let out = await orch.completeHeadless(system: "s", user: "u", onToken: { counter.record($0) })
        XCTAssertEqual(out, "A short answer.")
        XCTAssertGreaterThan(counter.last, 0)
    }

    // MARK: Focus filter

    func testFocusFilterQuietsOnlyWorkflowReminders() throws {
        let predicate = try XCTUnwrap(NotificationFilter.predicate(quietReminders: true))
        XCTAssertFalse(predicate.evaluate(with: NotificationFilter.workflowReminder))
        XCTAssertTrue(predicate.evaluate(with: "timer"))
        XCTAssertNil(NotificationFilter.predicate(quietReminders: false))
    }

    func testFocusFilterSetsNewChatMemoryScope() {
        XCTAssertEqual(FocusSettings.newChatMemoryScope(defaults), .global)
        FocusSettings.apply(quietReminders: true, isolateNewChats: true, defaults: defaults)
        XCTAssertEqual(FocusSettings.newChatMemoryScope(defaults), .isolated)
        FocusSettings.apply(quietReminders: false, isolateNewChats: false, defaults: defaults)
        XCTAssertEqual(FocusSettings.newChatMemoryScope(defaults), .global)
        XCTAssertEqual(AnuFocusFilter.summary(quietReminders: true, isolateNewChats: false), "Workflow reminders quiet")
    }
}

/// Thread-safe last-value box for the token callback.
private final class TokenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var last: Int { lock.lock(); defer { lock.unlock() }; return value }
    func record(_ n: Int) { lock.lock(); value = n; lock.unlock() }
}

/// What a Spotlight index would hold, by entity type.
@available(iOS 18.0, macOS 15.0, *)
private final class RecordingIndex: EntityIndexBackend {
    private var held: [String: [UUID]] = [:]
    private(set) var purges: [String] = []

    func ids<E>(_ type: E.Type) -> [UUID] { held[String(describing: type)] ?? [] }

    func index<E: IndexedEntity>(_ entities: [E]) async throws {
        let key = String(describing: E.self)
        for case let id as UUID in entities.map({ $0.id as Any }) where !(held[key] ?? []).contains(id) {
            held[key, default: []].append(id)
        }
    }
    func delete<E: IndexedEntity>(ids: [E.ID], of type: E.Type) async throws {
        let gone = Set(ids.compactMap { $0 as? UUID })
        held[String(describing: type)]?.removeAll { gone.contains($0) }
    }
    func deleteAll<E: IndexedEntity>(of type: E.Type) async throws {
        held[String(describing: type)] = []
        purges.append(String(describing: type))
    }
}
