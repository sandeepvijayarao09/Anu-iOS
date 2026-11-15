import CryptoKit
import XCTest
@testable import Anu

/// The model's memory tools (Android `MemoryTools.kt`): their risk tiers through
/// the broker, the chat's memory access, and About this answer's links to facts.
@MainActor
final class MemoryToolsTests: XCTestCase {
    private var dir: URL!
    private var store: MemoryStore!
    private var access: MemoryAccess = .full
    private var registry: ToolRegistry!
    private var approvals: ApprovalCenter!
    private var broker: ToolBroker!
    private var asked: [ApprovalRequest] = []
    private var answer: ApprovalDecision = .approved

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("memtools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = MemoryStore(directory: dir, keys: StaticDataKey(key: SymmetricKey(size: .bits256)), embedder: nil)
        access = .full
        asked = []
        answer = .approved
        registry = ToolRegistry()
        approvals = ApprovalCenter()
        approvals.autoDecide = { [unowned self] request in
            self.asked.append(request)
            return self.answer
        }
        broker = ToolBroker(registry: registry, approvals: approvals, audit: ToolAuditLog(fileURL: nil))
        let context = MemoryToolContext(store: { [unowned self] in self.store },
                                        access: { [unowned self] in self.access })
        MemoryTools.makeAll(context).forEach { registry.register($0) }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func call(_ name: String, _ args: [String: JSONValue]) -> ToolCallInfo {
        ToolCallInfo(name: name, arguments: .object(args))
    }

    private func remember(_ what: String, _ value: String, about: String = "user", section: String = "work") -> ToolCallInfo {
        call(MemoryTools.remember, ["about": .string(about), "what": .string(what), "value": .string(value), "section": .string(section)])
    }

    // MARK: Remember

    func testRememberIsAPrivateWriteThatRunsByItself() async {
        let outcome = await broker.handle(remember("manager", "Maya Chen"), run: RunState(turnKey: "t"))
        guard case .ok(let result, let summary, let wrote) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(asked.isEmpty, "an untainted private write runs by itself")
        XCTAssertTrue(wrote)
        XCTAssertEqual(summary, "Remember “Your manager: Maya Chen”")
        XCTAssertTrue(result.contains("Your manager: Maya Chen"), result)
        let fact = try? XCTUnwrap(store.shown.first)
        XCTAssertEqual(fact?.predicate, "manager")
        XCTAssertEqual(fact?.origin, .userStated, "the user's own word (P5)")
        XCTAssertEqual(fact?.section, .work)
    }

    func testRememberAsksWhenTheTurnIsTainted() async {
        let run = RunState(turnKey: "t")
        run.taint()
        answer = .denied
        let outcome = await broker.handle(remember("diet", "vegetarian", section: "preferences"), run: run)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.risk, .writePrivate)
        XCTAssertEqual(asked.first?.reason, "This request read content written by others")
        guard case .rejected(_, _, .declined) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(store.shown.isEmpty, "declined: nothing kept")
    }

    func testRememberReplacesAOneAtATimeRelation() async {
        _ = await broker.handle(remember("lives_in", "Pune", section: "places"), run: RunState(turnKey: "a"))
        _ = await broker.handle(remember("residence", "Bengaluru", section: "places"), run: RunState(turnKey: "b"))
        XCTAssertEqual(store.shown.map(\.value), ["Bengaluru"], "the canonical relation replaces the old home")
    }

    func testRememberRefusesSecrets() async {
        let outcome = await broker.handle(remember("wifi_password", "hunter2", section: "notes"), run: RunState(turnKey: "t"))
        guard case .failed(let reason, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(reason, ToolError.executionFailed(MemoryTools.refusesSecrets).localizedDescription)
        XCTAssertTrue(store.shown.isEmpty)
    }

    func testIncognitoKeepsNothingAndASandboxTouchesNothing() async {
        access = .noWrites
        let incognito = await broker.handle(remember("manager", "Maya Chen"), run: RunState(turnKey: "a"))
        guard case .failed(let why, _) = incognito else { return XCTFail("\(incognito)") }
        XCTAssertTrue(why.contains("incognito"), why)
        XCTAssertTrue(store.shown.isEmpty)

        store.remember(about: "user", what: "diet", value: "vegetarian", section: .preferences)
        access = .off
        let search = await broker.handle(call(MemoryTools.search, ["query": .string("diet")]), run: RunState(turnKey: "b"))
        guard case .failed(let off, _) = search else { return XCTFail("\(search)") }
        XCTAssertTrue(off.contains("private chat"), off)
    }

    func testAccessFollowsTheSessionAndHidesToolsItCantUse() {
        XCTAssertEqual(MemoryAccess(session: nil), .full)
        XCTAssertEqual(MemoryAccess(session: ChatSession()), .full)
        XCTAssertEqual(MemoryAccess(session: ChatSession(ephemeral: true)), .noWrites)
        XCTAssertEqual(MemoryAccess(session: ChatSession(memoryScope: .isolated)), .off)

        XCTAssertTrue(MemoryAccess.noWrites.offers(MemoryTools.search))
        XCTAssertTrue(MemoryAccess.noWrites.offers(MemoryTools.forget))
        XCTAssertFalse(MemoryAccess.noWrites.offers(MemoryTools.remember))
        XCTAssertFalse(MemoryAccess.off.offers(MemoryTools.search))
        XCTAssertTrue(MemoryAccess.off.offers("calendar"), "other tools are untouched")
    }

    // MARK: Search

    func testSearchIsAReadAndGivesIDs() async throws {
        let fact = try XCTUnwrap(store.remember(about: "Maya Chen", what: "birthday", value: "12 March", section: .people))
        store.remember(about: "user", what: "diet", value: "vegetarian", section: .preferences)
        let outcome = await broker.handle(call(MemoryTools.search, ["query": .string("Maya birthday")]), run: RunState(turnKey: "t"))
        guard case .ok(let result, let summary, let wrote) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(asked.isEmpty)
        XCTAssertFalse(wrote)
        XCTAssertEqual(summary, "Look up what you remember about “Maya birthday”")
        XCTAssertTrue(result.contains(fact.id.uuidString), result)
        XCTAssertTrue(result.contains("the user said so"), result)
        XCTAssertFalse(result.lowercased().contains("vegetarian"), result)
    }

    func testEmptySearchGivesTheMostImportantFacts() async {
        let empty = await broker.handle(call(MemoryTools.search, [:]), run: RunState(turnKey: "a"))
        XCTAssertEqual(empty, .ok(result: "Memory is empty.", summary: "Look up what you remember", wrote: false))
        store.remember(about: "user", what: "diet", value: "vegetarian", section: .preferences)
        let some = await broker.handle(call(MemoryTools.search, [:]), run: RunState(turnKey: "b"))
        guard case .ok(let result, _, _) = some else { return XCTFail("\(some)") }
        XCTAssertTrue(result.lowercased().contains("vegetarian"), result)
    }

    // MARK: Forget

    func testForgetAlwaysAsksWithTheExactFactsAndDeletesOnlyThose() async throws {
        let manager = try XCTUnwrap(store.remember(about: "user", what: "manager", value: "Maya Chen", section: .work))
        let diet = try XCTUnwrap(store.remember(about: "user", what: "diet", value: "vegetarian", section: .preferences))
        let outcome = await broker.handle(call(MemoryTools.forget, ["query": .string("manager")]), run: RunState(turnKey: "t"))

        XCTAssertEqual(asked.count, 1, "deleting always asks")
        XCTAssertEqual(asked.first?.risk, .destructive)
        XCTAssertEqual(asked.first?.summary, "Forget “Your manager: Maya Chen”")
        guard case .ok(let result, _, true) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(result.contains("Maya Chen"), result)
        XCTAssertNil(store.fact(id: manager.id))
        XCTAssertNotNil(store.fact(id: diet.id))
    }

    func testForgetDeletesWhatWasApprovedEvenIfMemoryChangesInBetween() async throws {
        let first = try XCTUnwrap(store.remember(about: "user", what: "likes", value: "green tea", section: .preferences))
        approvals.autoDecide = { [unowned self] request in
            self.asked.append(request)
            // While the sheet is up, a new matching fact arrives.
            self.store.remember(about: "user", what: "likes", value: "black tea", section: .preferences)
            return .approved
        }
        _ = await broker.handle(call(MemoryTools.forget, ["query": .string("tea")]), run: RunState(turnKey: "t"))
        XCTAssertNil(store.fact(id: first.id))
        XCTAssertEqual(store.shown.map(\.value), ["black tea"], "only the approved list is deleted")
    }

    func testForgetByIDAndForgetNothing() async throws {
        let fact = try XCTUnwrap(store.remember(about: "user", what: "diet", value: "vegan", section: .preferences))
        _ = await broker.handle(call(MemoryTools.forget, ["ids": .array([.string(fact.id.uuidString)])]), run: RunState(turnKey: "a"))
        XCTAssertTrue(store.shown.isEmpty)
        XCTAssertEqual(asked.count, 1)

        asked = []
        let nothing = await broker.handle(call(MemoryTools.forget, ["query": .string("pizza")]), run: RunState(turnKey: "b"))
        XCTAssertTrue(asked.isEmpty, "nothing to delete: nothing to approve")
        guard case .ok(let result, _, false) = nothing else { return XCTFail("\(nothing)") }
        XCTAssertTrue(result.contains("nothing was forgotten"), result)
    }

    func testAForgottenFactIsNotLearnedAgainFromChat() async throws {
        let fact = try XCTUnwrap(store.remember(about: "user", what: "diet", value: "vegan", section: .preferences))
        _ = await broker.handle(call(MemoryTools.forget, ["ids": .array([.string(fact.id.uuidString)])]), run: RunState(turnKey: "t"))
        let event = try XCTUnwrap(store.captureChat("I'm vegan these days, my diet is vegan"))
        let learned = store.learn([ExtractedFact(subject: "user", predicate: "diet", value: "vegan", section: .preferences, quote: "my diet is vegan")],
                                  from: event.id)
        XCTAssertEqual(learned, 0, "a deleted fact leaves a fingerprint, so chat doesn't bring it back (ADR-057)")
    }

    // MARK: Offered by their words

    func testTheirWordsOfferThem() {
        let tools = registry.allTools + [CalculatorTool(), DateTimeTool()]
        func offered(_ text: String) -> Set<String> {
            Set(ToolSelector.select(tools, turns: [text], escalation: nil).map(\.name))
        }
        XCTAssertTrue(offered("Please remember that my manager is Maya").contains(MemoryTools.remember))
        XCTAssertTrue(offered("What do you know about my sister?").contains(MemoryTools.search))
        XCTAssertTrue(offered("Forget my old address").contains(MemoryTools.forget))
        XCTAssertFalse(offered("What is 12 times 7?").contains(MemoryTools.forget))
    }

    // MARK: About this answer links to Memory

    func testAboutThisAnswerLinksTheFactsItUsed() throws {
        let kept = try XCTUnwrap(store.remember(about: "user", what: "diet", value: "vegetarian", section: .preferences))
        let gone = try XCTUnwrap(store.remember(about: "user", what: "manager", value: "Maya", section: .work))
        var details = AnswerDetails(tier: .onDevice, modelName: "M", memoryNotes: 2)
        details.memoryFactIDs = [kept.id, gone.id]
        store.delete(id: gone.id)

        let linked = AnswerDetailsText.linkedFacts(details, in: store.facts)
        XCTAssertEqual(linked.facts.map(\.id), [kept.id])
        XCTAssertEqual(linked.gone, 1)
        XCTAssertEqual(AnswerDetailsText.goneFacts(1), "1 fact it used has since been removed from Memory")
        XCTAssertNil(AnswerDetailsText.goneFacts(0))

        let data = try JSONEncoder().encode(details)
        XCTAssertEqual(try JSONDecoder().decode(AnswerDetails.self, from: data).memoryFactIDs, [kept.id, gone.id])
        let old = try JSONDecoder().decode(AnswerDetails.self, from: Data(#"{"tier":"onDevice","modelName":"M","memoryNotes":1}"#.utf8))
        XCTAssertNil(old.memoryFactIDs, "answers saved before ids were kept still decode")
        XCTAssertTrue(AnswerDetailsText.linkedFacts(old, in: store.facts).facts.isEmpty)
    }

    func testAnAnswerKeepsTheIDsOfTheMemoryInItsPrompt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("memlink-\(UUID().uuidString)", isDirectory: true)
        let orch = AgentOrchestrator(model: QueuedMockModel(["Hello!"]), sessionsDirectory: dir)
        let fact = try XCTUnwrap(MemoryStore.shared.remember(about: "user", what: "favorite_drink", value: "masala chai zz\(UUID().uuidString.prefix(4))", section: .preferences))
        defer { MemoryStore.shared.delete(id: fact.id) }
        await orch.run(userMessage: "hello, what is my favorite drink?")
        let details = try XCTUnwrap(orch.messages.last { $0.role == .assistant }?.details)
        XCTAssertTrue(details.memoryFactIDs?.contains(fact.id) == true, "\(String(describing: details.memoryFactIDs))")
        XCTAssertEqual(details.memoryNotes, details.memoryFactIDs?.count)
    }
}
