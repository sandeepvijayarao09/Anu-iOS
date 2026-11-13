import CryptoKit
import XCTest
@testable import Anu

/// Memory v2, steps 3–4 and user control: reconcile (dedupe, supersede, the
/// user's word stands), dated facts coming true, delete/correct/confirm/forget
/// a source, and the learning loop's failure handling (P6).
@MainActor
final class MemoryPipelineTests: XCTestCase {
    private var dir: URL!
    private var now: Date!
    /// The app's calendar: facts' days are shown in the device's own time zone.
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()
    private let keys = StaticDataKey(key: SymmetricKey(size: .bits256))

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("memory-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 10))!
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() -> MemoryStore {
        MemoryStore(directory: dir, keys: keys, embedder: nil, calendar: calendar, clock: { [unowned self] in self.now })
    }

    private func fact(_ predicate: String, _ value: String, subject: String = "user", section: FactSection = .identity,
                      quote: String? = nil, single: Bool = false, starts: String? = nil) -> ExtractedFact {
        ExtractedFact(subject: subject, predicate: predicate, value: value, section: section,
                      quote: quote ?? value, single: single, starts: starts)
    }

    /// Captures `text` as a chat message and learns `facts` from it.
    @discardableResult
    private func say(_ store: MemoryStore, _ text: String, _ facts: [ExtractedFact]) -> MemoryEvent {
        let event = store.captureChat(text, ref: "chat:test", place: "Test chat")!
        store.learn(facts, from: event.id)
        return event
    }

    private func active(_ store: MemoryStore, _ predicate: String) -> [MemoryFact] {
        store.facts.filter { $0.predicate == predicate && $0.status == .active }
    }

    // MARK: Reconcile

    func testRepeatAddsSourceAndConfidenceInsteadOfDuplicating() throws {
        let store = makeStore()
        say(store, "I'm vegetarian", [fact("diet", "vegetarian", section: .preferences)])
        now += 3600
        say(store, "As a vegetarian I skip meat", [fact("dietary_preference", "Vegetarian", section: .preferences)])
        let diet = try XCTUnwrap(active(store, "diet").first)
        XCTAssertEqual(active(store, "diet").count, 1, "deduped")
        XCTAssertEqual(diet.sources.count, 2)
        XCTAssertEqual(diet.confidence, 0.75, accuracy: 0.001)
        XCTAssertEqual(diet.badge, .needsConfirming)
        XCTAssertEqual(store.sources(of: diet).first?.place, "Test chat", "dated sources keep where they were said")
        XCTAssertEqual(diet.history.count, 2)
    }

    func testNewerValueSupersedesOlderOneAtATimeRelation() throws {
        let store = makeStore()
        say(store, "I work at Acme", [fact("works_at", "Acme", section: .work)])
        say(store, "My employer is Globex now", [fact("employer", "Globex", section: .work)])
        let current = active(store, "works_at")
        XCTAssertEqual(current.map(\.value), ["Globex"])
        let old = try XCTUnwrap(store.facts.first { $0.value == "Acme" })
        XCTAssertEqual(old.status, .superseded, "kept in history")
        XCTAssertEqual(old.supersededBy, current.first?.id)
        XCTAssertFalse(store.shown.contains { $0.value == "Acme" })
    }

    func testInferredFactNeverReplacesTheUsersWord() {
        let store = makeStore()
        let event = store.add("I live in Pune")!
        store.learn([fact("lives_in", "Pune", section: .places)], from: event.sources[0])
        say(store, "my sister said she loves our place in Mumbai", [fact("lives_in", "Mumbai", section: .places)])
        XCTAssertEqual(active(store, "lives_in").map(\.value), ["Pune"])
        XCTAssertEqual(active(store, "lives_in").first?.badge, .youSaid)
    }

    func testStatementNoteIsReplacedByStructuredFacts() {
        let store = makeStore()
        let note = store.add("My manager is Maya and I'm vegan")!
        XCTAssertTrue(note.isNote)
        XCTAssertEqual(store.pendingCount, 1, "waiting to be filed by the model")
        store.learn([fact("manager", "Maya", section: .people), fact("diet", "vegan", section: .preferences)], from: note.sources[0])
        XCTAssertFalse(store.shown.contains { $0.isNote })
        XCTAssertEqual(Set(store.shown.map(\.predicate)), ["manager", "diet"])
        XCTAssertTrue(store.shown.allSatisfy { $0.origin == .userStated }, "what the user said directly stays theirs")
    }

    // MARK: Dated facts (ADR-147)

    func testUpcomingFactReplacesNothingUntilItsDay() throws {
        let store = makeStore()
        say(store, "I live in Austin", [fact("lives_in", "Austin", section: .places)])
        say(store, "I'm moving to Denver next month", [fact("moving_to", "Denver", section: .places, quote: "I'm moving to Denver next month")])
        XCTAssertEqual(active(store, "lives_in").map(\.value), ["Austin"])
        let plan = try XCTUnwrap(store.facts.first { $0.value == "Denver" })
        XCTAssertEqual(plan.status, .upcoming)
        XCTAssertEqual(plan.startsOn, calendar.date(from: DateComponents(year: 2026, month: 12, day: 1)))
        XCTAssertTrue(plan.text.hasSuffix("(from 1 December 2026)"))
        XCTAssertEqual(MemoryFactWords(plan), MemoryFactWords(label: "Lives in Denver", relationship: "From 1 December 2026"),
                       "a verb relation reads as a sentence; the day is its second line")

        now = calendar.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 8))!
        store.activateDue()
        XCTAssertEqual(active(store, "lives_in").map(\.value), ["Denver"])
        XCTAssertEqual(store.facts.first { $0.value == "Austin" }?.status, .superseded)
    }

    func testNewPlanReplacesOldPlan() {
        let store = makeStore()
        say(store, "I'm moving to Denver next month", [fact("lives_in", "Denver", quote: "I'm moving to Denver next month")])
        say(store, "Actually I'm moving to Chicago next month", [fact("lives_in", "Chicago", quote: "I'm moving to Chicago next month")])
        XCTAssertEqual(store.facts.filter { $0.status == .upcoming }.map(\.value), ["Chicago"])
    }

    // MARK: User control

    func testDeletedFactIsNotLearnedAgainFromChatButTheUsersWordBringsItBack() throws {
        let store = makeStore()
        say(store, "I'm vegan", [fact("diet", "vegan")])
        store.delete(id: try XCTUnwrap(active(store, "diet").first).id)
        say(store, "I'm vegan still", [fact("diet", "vegan")])
        XCTAssertTrue(active(store, "diet").isEmpty, "fingerprint blocks relearning")
        let statement = store.add("I'm vegan")!
        store.learn([fact("diet", "vegan")], from: statement.sources[0])
        XCTAssertEqual(active(store, "diet").map(\.value), ["vegan"])
    }

    func testCorrectKeepsHistoryAndBlocksTheOldValue() throws {
        let store = makeStore()
        say(store, "my manager is Mia", [fact("manager", "Mia", section: .people)])
        let id = try XCTUnwrap(active(store, "manager").first).id
        store.correct(id: id, value: "Maya")
        let corrected = try XCTUnwrap(store.fact(id: id))
        XCTAssertEqual(corrected.value, "Maya")
        XCTAssertEqual(corrected.badge, .confirmed)
        XCTAssertTrue(corrected.history.contains { $0.change.contains("“Mia”") })
        XCTAssertEqual(store.sources(of: corrected).first?.source, .edit)
        say(store, "my manager is Mia", [fact("manager", "Mia", section: .people)])
        XCTAssertEqual(active(store, "manager").map(\.value), ["Maya"])
    }

    func testConfirmMakesItTheUsers() throws {
        let store = makeStore()
        say(store, "I like climbing", [fact("likes", "climbing")])
        let id = try XCTUnwrap(active(store, "likes").first).id
        store.confirm(id: id)
        let confirmed = try XCTUnwrap(store.fact(id: id))
        XCTAssertEqual(confirmed.origin, .userStated)
        XCTAssertEqual(confirmed.confidence, 1)
        XCTAssertEqual(confirmed.badge, .confirmed)
        XCTAssertEqual(confirmed.sources.count, 2, "the confirmation is a source too (I4)")
    }

    func testForgettingASourceRemovesWhatCameOnlyFromItAndRestoresWhatItReplaced() {
        let store = makeStore()
        say(store, "I work at Acme", [fact("works_at", "Acme")])
        let event = say(store, "I work at Globex", [fact("works_at", "Globex")])
        store.forgetSource(event.id)
        XCTAssertEqual(active(store, "works_at").map(\.value), ["Acme"])
        XCTAssertFalse(store.events.contains { $0.id == event.id })
    }

    func testPersistsEncryptedAndReloads() throws {
        let store = makeStore()
        say(store, "I'm vegan", [fact("diet", "vegan")])
        XCTAssertTrue(SecureFile.isEncrypted(dir.appendingPathComponent("memory.json")))
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.shown.map(\.value), ["vegan"])
        XCTAssertEqual(reloaded.sources(of: reloaded.shown[0]).count, 1)
    }

    func testMigratesEarlierMemoryNotes() throws {
        let legacy = """
        [{"id":"11111111-1111-1111-1111-111111111111","content":"My dog's name is Biscuit","createdAt":700000000,"updatedAt":700000500}]
        """
        try SecureFile.write(Data(legacy.utf8), to: dir.appendingPathComponent("memory.json"), keys: keys)
        let store = makeStore()
        let note = try XCTUnwrap(store.shown.first)
        XCTAssertEqual(note.id.uuidString, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(note.text, "My dog's name is Biscuit")
        XCTAssertEqual(note.section, .notes)
        XCTAssertEqual(note.badge, .youSaid)
        XCTAssertEqual(store.sources(of: note).first?.source, .migrated)
        XCTAssertEqual(note.history.count, 2, "saved, then edited")
        XCTAssertEqual(store.pendingCount, 0, "migrated notes are kept exactly as written")
        XCTAssertEqual(makeStore().shown.count, 1, "migration is saved in the new format")
    }

    // MARK: The learning loop

    func testLearningLoopLearnsAndRetriesFailuresThenDrops() async {
        let store = makeStore()
        store.captureChat("I'm vegetarian, by the way")
        now += 1
        store.captureChat("My sister Priya lives in Pune")
        let model = QueuedMockModel([
            #"{"facts":[{"subject":"user","predicate":"diet","value":"vegetarian","section":"preferences","quote":"I'm vegetarian"}]}"#,
            "garbage", "more garbage",
        ])
        let first = await MemoryLearner.process(store: store, model: model, today: now)
        XCTAssertEqual(first.processed, 1)
        XCTAssertEqual(first.learned, 1)
        XCTAssertEqual(first.failed, 1)
        XCTAssertEqual(store.pendingCount, 1, "the failed message waits for a later run")

        for _ in 0..<2 {
            _ = await MemoryLearner.process(store: store, model: QueuedMockModel(["x", "y"]), today: now)
        }
        XCTAssertEqual(store.pendingCount, 0, "dropped after \(MemoryStore.maxAttempts) attempts")
        XCTAssertEqual(store.shown.map(\.value), ["vegetarian"])
    }

    func testLearningStopsWhenAChatNeedsTheModel() async {
        let store = makeStore()
        store.captureChat("I'm vegetarian, by the way")
        now += 1
        store.captureChat("I'm vegan now actually")
        let model = QueuedMockModel([#"{"facts":[]}"#, #"{"facts":[]}"#])
        var calls = 0
        let result = await MemoryLearner.process(store: store, model: model, today: now) {
            calls += 1
            return calls == 1
        }
        XCTAssertEqual(result.processed, 1)
        XCTAssertEqual(store.pendingCount, 1)
    }

    func testLearnerReportsNoModelAndLearnsWithScriptedModel() async {
        let store = makeStore()
        store.captureChat("I'm vegetarian, honestly")
        let none = MemoryLearner(store: store, modelProvider: { nil }, modelBusy: { false })
        let r1 = await none.learnNow()
        XCTAssertTrue(r1.noModel)
        XCTAssertEqual(store.pendingCount, 1)

        let scripted = MemoryLearner(store: store, modelProvider: { ScriptedModel() }, modelBusy: { false })
        let r2 = await scripted.learnNow()
        XCTAssertEqual(r2.learned, 1)
        XCTAssertEqual(store.shown.first?.text, "diet: vegetarian")
        XCTAssertFalse(scripted.isLearning)
    }
}
