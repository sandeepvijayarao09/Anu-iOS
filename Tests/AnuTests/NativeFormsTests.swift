import CryptoKit
import XCTest
@testable import Anu

// The iOS forms of Android features iOS blocks: live talk's Live Activity
// (ADR-108), Anu's notes (ADR-093), the Daily Brief, and questions about a
// screenshot (ADR-083). No network, no model: fakes and closures only.

// MARK: - Notes

final class NoteStoreTests: XCTestCase {
    private var dir: URL!
    private let keys = StaticDataKey(key: SymmetricKey(size: .bits256))

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func store(clock: @escaping @Sendable () -> Date = Date.init) -> NoteStore {
        NoteStore(directory: dir, keys: keys, clock: clock)
    }

    func testAddSavesEncryptedAndReloads() throws {
        let notes = store()
        let note = try notes.add(title: "Groceries", text: "oat milk, eggs")
        let url = dir.appendingPathComponent("notes.json")
        XCTAssertTrue(SecureFile.isEncrypted(url), "notes are personal data: SecureFile only")
        XCTAssertNil(try Data(contentsOf: url).range(of: Data("oat milk".utf8)), "no plaintext on disk")
        XCTAssertEqual(store().all, [note], "a fresh store reads it back")
    }

    func testUntitledNoteTakesItsFirstWords() throws {
        let note = try store().add(text: "Call the plumber about the kitchen tap before the weekend please\nsecond line")
        XCTAssertEqual(note.title, "Call the plumber about the kitchen tap…")
        XCTAssertEqual(NoteStore.firstWords("Short one"), "Short one")
    }

    func testRefusesEmptyAndOversizedNotes() {
        let notes = store()
        XCTAssertThrowsError(try notes.add(text: "   ")) { XCTAssertEqual($0 as? NoteError, .empty) }
        XCTAssertThrowsError(try notes.add(text: String(repeating: "a", count: NoteStore.maxText + 1))) {
            XCTAssertEqual($0 as? NoteError, .tooLong)
        }
        XCTAssertThrowsError(try notes.add(title: String(repeating: "t", count: NoteStore.maxTitle + 1), text: "x")) {
            XCTAssertEqual($0 as? NoteError, .titleTooLong)
        }
    }

    func testSearchMatchesEveryWordIgnoringFillerNewestFirst() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let lock = NSLock()
        let notes = store(clock: { lock.withLock { now } })
        try notes.add(title: "Groceries", text: "oat milk, eggs")
        lock.withLock { now = now.addingTimeInterval(60) }
        try notes.add(title: "Trip", text: "pack the oat bars")
        XCTAssertEqual(notes.search("oat").map(\.title), ["Trip", "Groceries"])
        XCTAssertEqual(notes.search("my groceries note").map(\.title), ["Groceries"])
        XCTAssertEqual(notes.search("oat milk").map(\.title), ["Groceries"])
        XCTAssertTrue(notes.search("pineapple").isEmpty)
        XCTAssertEqual(notes.search("").count, 2, "an empty query lists the newest")
        XCTAssertEqual(NoteStore.searchable("the notes"), "the notes", "all filler: kept as it is")
    }

    func testUpdateAndDelete() throws {
        let notes = store()
        let note = try notes.add(title: "Idea", text: "first")
        let updated = try notes.update(id: note.id, title: "", text: "second thoughts")
        XCTAssertEqual(updated.title, "second thoughts")
        XCTAssertEqual(store().note(id: note.id)?.text, "second thoughts")
        notes.delete(id: note.id)
        XCTAssertTrue(store().all.isEmpty)
        XCTAssertThrowsError(try notes.update(id: note.id, title: "", text: "x")) {
            XCTAssertEqual($0 as? NoteError, .notFound)
        }
    }

    func testShareTextLeadsWithTheTitle() {
        let now = Date()
        XCTAssertEqual(NoteStore.shareText(Note(id: UUID(), title: "Groceries", text: "eggs", created: now, updated: now)),
                       "Groceries\n\neggs")
        XCTAssertEqual(NoteStore.shareText(Note(id: UUID(), title: "eggs and", text: "eggs and milk", created: now, updated: now)),
                       "eggs and milk")
    }
}

/// The notes tools go through the broker like every other tool call.
@MainActor
final class NotesToolsTests: XCTestCase {
    private var dir: URL!
    private var notes: NoteStore!
    private var registry: ToolRegistry!
    private var approvals: ApprovalCenter!
    private var broker: ToolBroker!
    private var asked: [ApprovalRequest] = []
    private var answer: ApprovalDecision = .approved

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-tools-\(UUID().uuidString)")
        notes = NoteStore(directory: dir, keys: StaticDataKey(key: SymmetricKey(size: .bits256)))
        registry = ToolRegistry()
        NotesTools.register(in: registry, store: notes)
        approvals = ApprovalCenter()
        asked = []
        answer = .approved
        approvals.autoDecide = { [unowned self] request in
            self.asked.append(request)
            return self.answer
        }
        broker = ToolBroker(registry: registry, approvals: approvals, audit: ToolAuditLog(fileURL: nil))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func call(_ name: String, _ args: [String: JSONValue]) -> ToolCallInfo {
        ToolCallInfo(name: name, arguments: .object(args))
    }

    func testRegistersTheThreeTools() {
        XCTAssertEqual(Set(NotesTools.names).subtracting(registry.toolNames), [])
        XCTAssertEqual(NotesAddTool(store: notes).risk(for: .object([:])), .writePrivate)
        XCTAssertEqual(NotesSearchTool(store: notes).risk(for: .object([:])), .read)
        XCTAssertEqual(NotesListTool(store: notes).risk(for: .object([:])), .read)
        XCTAssertFalse(NotesSearchTool(store: notes).returnsUntrustedContent(for: .object([:])), "the user's own words")
    }

    func testAddIsAPrivateWriteThatRunsByItselfWithAReceipt() async {
        let run = RunState(turnKey: "t")
        let outcome = await broker.handle(call("notes_add", ["title": .string("Groceries"), "text": .string("oat milk")]), run: run)
        XCTAssertEqual(outcome, .ok(result: "Saved the note “Groceries” in Anu.",
                                    summary: "Save a note in Anu, “Groceries”", wrote: true))
        XCTAssertTrue(asked.isEmpty, "an untainted private write runs by itself")
        XCTAssertEqual(run.receipts.map(\.status), [.done])
        XCTAssertEqual(notes.all.map(\.text), ["oat milk"])
    }

    func testAddInATaintedRunAsksWithTheExactNoteAndHonoursANo() async {
        let run = RunState(turnKey: "t")
        run.taint()
        answer = .denied
        let outcome = await broker.handle(call("notes_add", ["text": .string("wire money to this account")]), run: run)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.payload["text"]?.stringValue, "wire money to this account")
        XCTAssertEqual(asked.first?.editableFields.map(\.key), ["title", "text"])
        guard case .rejected(_, _, .declined) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(notes.all.isEmpty, "a declined note isn't saved")
    }

    func testAddWithoutTextIsInvalidAndNeverRuns() async {
        let outcome = await broker.handle(call("notes_add", ["title": .string("Empty")]), run: RunState(turnKey: "t"))
        guard case .invalid = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(notes.all.isEmpty)
    }

    func testSearchAndListAreReads() async throws {
        try notes.add(title: "Groceries", text: "oat milk, eggs")
        try notes.add(title: "Packing", text: "charger, passport")
        let run = RunState(turnKey: "t")
        let found = await broker.handle(call("notes_search", ["query": .string("my groceries list")]), run: run)
        XCTAssertEqual(found.observation, "• Groceries: oat milk, eggs")
        let none = await broker.handle(call("notes_search", ["query": .string("tennis")]), run: run)
        XCTAssertEqual(none.observation, "No note has “tennis”.")
        let listed = await broker.handle(call("notes_list", ["limit": .int(1)]), run: run)
        XCTAssertEqual(listed.observation, "• Packing: charger, passport\n(2 notes in all.)")
        XCTAssertTrue(asked.isEmpty)
        XCTAssertTrue(run.receipts.isEmpty, "reads leave no action receipt")
        XCTAssertFalse(run.tainted)
    }

    func testListWhenEmpty() async {
        let outcome = await broker.handle(call("notes_list", [:]), run: RunState(turnKey: "t"))
        XCTAssertEqual(outcome.observation, "There are no notes in Anu yet.")
    }

    func testANoteTurnIsOfferedTheNotesTools() {
        let all = registry.allTools + [CalculatorTool(), DateTimeTool()]
        let names = ToolSelector.select(all, turns: ["make a note: buy oat milk"], escalation: nil).map(\.name)
        XCTAssertTrue(names.contains("notes_add"), "\(names)")
    }

    func testTheAppRegistersTheNotesTools() {
        let orchestrator = AgentOrchestrator(model: QueuedMockModel([]), sessionsDirectory: dir)
        for name in NotesTools.names { XCTAssertNotNil(orchestrator.toolRegistry.tool(named: name), name) }
    }
}

// MARK: - Live talk behind other apps

final class LiveTalkMuteTests: XCTestCase {
    func testMuteStopsRelisteningAndUnmuteListensAtOnce() {
        var talk = LiveTalk()
        _ = talk.start()
        XCTAssertEqual(talk.setMuted(true), .none)
        XCTAssertTrue(talk.muted)
        XCTAssertEqual(talk.answerDone(isThinking: false, awaitingApproval: false, isSpeaking: false), .none,
                       "muted: Anu answers but doesn't listen again")
        XCTAssertEqual(talk.bargedIn(), .none)
        XCTAssertEqual(talk.setMuted(false), .listen(afterMs: 0))
        XCTAssertEqual(talk.answerDone(isThinking: false, awaitingApproval: false, isSpeaking: false),
                       .listen(afterMs: LiveTalk.relistenDelayMs))
    }

    func testAListenStoppedByMuteIsNotAQuietOne() {
        var talk = LiveTalk()
        _ = talk.start()
        _ = talk.setMuted(true)
        for _ in 0..<LiveTalk.maxQuietListens + 1 {
            XCTAssertEqual(talk.listenEnded(heardWords: false), .none)
        }
        XCTAssertTrue(talk.active, "muting never ends live talk by itself")
    }

    func testStoppingClearsMuteAndMuteNeedsLiveTalk() {
        var talk = LiveTalk()
        XCTAssertEqual(talk.setMuted(true), .none)
        XCTAssertFalse(talk.muted, "nothing to mute when live talk is off")
        _ = talk.start()
        _ = talk.setMuted(true)
        talk.stop()
        XCTAssertFalse(talk.muted)
        _ = talk.start()
        XCTAssertFalse(talk.muted, "a new live talk starts unmuted")
    }

    @MainActor
    func testVoiceLoopMuteDropsTheListenInProgress() {
        let loop = VoiceLoop()
        var listening = true
        var discarded = 0, stopped = 0, started = 0
        loop.isListening = { listening }
        loop.discardListening = { discarded += 1; listening = false }
        loop.stopListening = { stopped += 1 }
        loop.startListening = { started += 1 }
        loop.after = { _, work in work() }
        loop.startLiveTalk(listen: false)
        loop.setMuted(true)
        XCTAssertEqual(discarded, 1, "what was half-said isn't sent")
        XCTAssertEqual(stopped, 0)
        loop.turnEnded()
        XCTAssertEqual(started, 0, "muted: no relisten after an answer")
        loop.setMuted(false)
        XCTAssertEqual(started, 1)
    }

    func testPhaseShownOnTheLiveActivity() {
        func phase(muted: Bool = false, listening: Bool = false, speaking: Bool = false,
                   thinking: Bool = false, approval: Bool = false, active: Bool = true) -> LiveTalkPhase? {
            LiveTalkPhase.current(active: active, muted: muted, listening: listening, speaking: speaking,
                                  thinking: thinking, awaitingApproval: approval)
        }
        XCTAssertNil(phase(listening: true, active: false))
        XCTAssertEqual(phase(listening: true), .listening)
        XCTAssertEqual(phase(thinking: true), .thinking)
        XCTAssertEqual(phase(speaking: true, thinking: true), .speaking)
        XCTAssertEqual(phase(thinking: true, approval: true), .waitingForYou)
        XCTAssertEqual(phase(muted: true, thinking: true), .muted)
        XCTAssertEqual(LiveTalkPhase.waitingForYou.hint, "Open Anu to approve or decline")
        XCTAssertEqual(LiveTalkPhase.listening.label, "Listening")
    }

    func testLeavingAnuNeedsTheLiveActivity() {
        XCTAssertEqual(LiveTalkBackgroundPolicy.onBackground(liveTalkActive: false, activityShowing: false), .nothing)
        XCTAssertEqual(LiveTalkBackgroundPolicy.onBackground(liveTalkActive: true, activityShowing: true), .keepGoing)
        XCTAssertEqual(LiveTalkBackgroundPolicy.onBackground(liveTalkActive: true, activityShowing: false),
                       .end(note: LiveTalkBackgroundPolicy.needsLiveActivity), "never talks unseen")
    }

    func testCommandsRoundTripThroughTheNotification() {
        let expectation = expectation(forNotification: .anuLiveTalkCommand, object: nil) { note in
            LiveTalkCommand.from(note) == .toggleMute
        }
        LiveTalkCommand.toggleMute.post()
        wait(for: [expectation], timeout: 1)
        XCTAssertNil(LiveTalkCommand.from(Notification(name: .anuLiveTalkCommand)))
    }

    func testTheBackgroundAudioModeIsDeclared() throws {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        #if os(iOS)
        XCTAssertTrue(modes.contains("audio"), "\(modes)")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool, true)
        #endif
    }
}

// MARK: - Daily Brief

private struct FakeBriefSource: DailyBriefCalendarSource {
    var events: Result<[DailyBrief.Event], BriefSourceProblem> = .success([])
    var reminders: Result<[DailyBrief.Reminder], BriefSourceProblem> = .success([])
    func events(on day: Date, calendar: Calendar) async -> Result<[DailyBrief.Event], BriefSourceProblem> { events }
    func reminders(dueBy day: Date, calendar: Calendar) async -> Result<[DailyBrief.Reminder], BriefSourceProblem> { reminders }
}

private final class FakeBriefCenter: DailyBriefNotificationCenter, @unchecked Sendable {
    var allowed = true
    var removed: [String] = []
    var added: [(String, String, String, DateComponents)] = []
    func requestAuthorization() async -> Bool { allowed }
    func removePending(identifiers: [String]) { removed += identifiers }
    func add(identifier: String, title: String, body: String, components: DateComponents) async {
        added.append((identifier, title, body, components))
    }
}

final class DailyBriefTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let locale = Locale(identifier: "en_US_POSIX")

    /// Times format with a narrow no-break space before AM/PM.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 13) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func sampleBrief() -> DailyBrief {
        DailyBrief(day: at(7),
                   events: [.init(title: "Standup", start: at(9), end: at(9, 15), allDay: false, location: "Room 4"),
                            .init(title: "Dentist", start: at(15), end: at(16), allDay: false, location: nil)],
                   reminders: [.init(title: "Pay rent", due: at(9, day: 12), overdue: true),
                               .init(title: "Call Maya", due: at(18), overdue: false)],
                   remembered: ["Maya · birthday: 13 November"],
                   notes: ["Groceries"])
    }

    func testPlainSummaryWithNoModel() {
        let text = plain(DailyBriefText.summary(sampleBrief(), calendar: calendar, locale: locale))
        XCTAssertEqual(text, "2 things on your calendar, the first at 9:00 AM (Standup). 2 reminders to do, 1 overdue. Remember: Maya · birthday: 13 November.")
        XCTAssertEqual(DailyBriefText.summary(DailyBrief(day: at(7)), calendar: calendar, locale: locale),
                       "Nothing is on your calendar today.")
        XCTAssertEqual(plain(DailyBriefText.line(sampleBrief().events[0], calendar: calendar, locale: locale)), "9:00 AM Standup · Room 4")
        XCTAssertEqual(DailyBriefText.line(sampleBrief().reminders[0], calendar: calendar, locale: locale), "Pay rent (overdue)")
    }

    func testFullTextHasEverySection() {
        let full = plain(DailyBriefText.full(sampleBrief(), calendar: calendar, locale: locale))
        for part in ["Calendar:\n- 9:00 AM Standup · Room 4", "Reminders due:\n- Pay rent (overdue)",
                     "Remembered about the user:\n- Maya", "Newest notes:\n- Groceries"] {
            XCTAssertTrue(full.contains(part), "missing \(part) in\n\(full)")
        }
    }

    func testWriterMakesOneOnDeviceCallWithOnlyTheGatheredFacts() async throws {
        let model = QueuedMockModel(["Morning! Standup at 9 in Room 4, and the rent is overdue.<end_of_turn>"])
        let written = await DailyBriefWriter.write(sampleBrief(), calendar: calendar) { prompt in
            var text = ""
            for await chunk in try await model.generate(prompt: prompt, config: .deterministic) { text += chunk }
            return text
        }
        XCTAssertEqual(written, "Morning! Standup at 9 in Room 4, and the rent is overdue.")
        XCTAssertEqual(model.capturedPrompts.count, 1)
        let prompt = try XCTUnwrap(model.capturedPrompts.first)
        XCTAssertTrue(prompt.contains(DailyBriefWriter.sentinel))
        XCTAssertTrue(prompt.contains("Standup"))
        XCTAssertFalse(prompt.contains("tool_call"), "the brief offers the model no tools")
    }

    func testWriterFallsBackWhenTheModelCantHelp() async {
        let failing: (String) async throws -> String = { _ in throw SideGenerationError.busy }
        let noAnswer = await DailyBriefWriter.write(sampleBrief(), calendar: calendar, generate: failing)
        XCTAssertNil(noAnswer)
        XCTAssertNil(DailyBriefWriter.clean("  "))
        XCTAssertNil(DailyBriefWriter.clean("[Generation error: no model]"))
        XCTAssertNil(DailyBriefWriter.clean(#"{"name":"calendar"}"#))
        var called = false
        let empty = await DailyBriefWriter.write(DailyBrief(day: at(7)), calendar: calendar) { _ in called = true; return "x" }
        XCTAssertNil(empty)
        XCTAssertFalse(called, "nothing to write up: no model call")
    }

    func testGatherReadsEachSourceAndKeepsProblems() async {
        let source = FakeBriefSource(
            events: .success(sampleBrief().events),
            reminders: .failure(BriefSourceProblem(message: "Reminders access not granted.")))
        var asked: [String] = []
        let brief = await DailyBriefGatherer.gather(
            day: at(7), calendar: calendar, source: source,
            memory: { titles in asked = titles; return ["fact"] },
            notes: { ["A", "B", "C", "D"] })
        XCTAssertEqual(brief.events.count, 2)
        XCTAssertTrue(brief.reminders.isEmpty)
        XCTAssertEqual(brief.problems, ["Reminders access not granted."])
        XCTAssertEqual(asked, ["Standup", "Dentist"], "memory is looked up by today's events")
        XCTAssertEqual(brief.remembered, ["fact"])
        XCTAssertEqual(brief.notes, ["A", "B", "C"], "the newest three notes")
    }

    func testRememberedPicksTodaysFactsAndLeavesPrivateOnesOut() {
        func fact(_ value: String, starts: Date? = nil, sensitive: Bool = false) -> MemoryFact {
            MemoryFact(subject: "user", predicate: "plan", value: value, section: .goals, confidence: 1,
                       origin: .userStated, status: starts == nil ? .active : .upcoming, sensitive: sensitive,
                       firstSeen: at(7, day: 1), sources: [], startsOn: starts)
        }
        let today = fact("new job", starts: at(0))
        let tomorrow = fact("holiday", starts: at(0, day: 14))
        let secret = fact("clinic visit", starts: at(0), sensitive: true)
        let related = fact("standup notes")
        let picked = DailyBriefGatherer.remembered(startingToday: [today, tomorrow, secret], relevant: [related, today],
                                                   day: at(7), calendar: calendar)
        XCTAssertEqual(picked.count, 2)
        XCTAssertTrue(picked[0].contains("new job"))
        XCTAssertTrue(picked[1].contains("standup notes"))
    }

    func testSchedulerKeepsOneQuietMorningNotification() async {
        let center = FakeBriefCenter()
        let ok = await DailyBriefScheduler.sync(DailyBriefSettings(enabled: true, hour: 6, minute: 45), center: center)
        XCTAssertTrue(ok)
        XCTAssertEqual(center.removed, [DailyBriefScheduler.identifier], "replaces, never stacks")
        XCTAssertEqual(center.added.count, 1)
        XCTAssertEqual(center.added[0].3, DateComponents(hour: 6, minute: 45))
        XCTAssertFalse(center.added[0].2.contains("Standup"), "the lock screen never shows the brief")

        let off = FakeBriefCenter()
        _ = await DailyBriefScheduler.sync(DailyBriefSettings(enabled: false), center: off)
        XCTAssertTrue(off.added.isEmpty)
        XCTAssertEqual(off.removed, [DailyBriefScheduler.identifier])

        let denied = FakeBriefCenter()
        denied.allowed = false
        let refused = await DailyBriefScheduler.sync(DailyBriefSettings(enabled: true), center: denied)
        XCTAssertFalse(refused)
        XCTAssertTrue(denied.added.isEmpty)
    }

    func testSettingsRoundTripAndClamp() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "brief-\(UUID().uuidString)"))
        XCTAssertEqual(DailyBriefSettings.load(defaults), DailyBriefSettings(enabled: false, hour: 7, minute: 30))
        DailyBriefSettings(enabled: true, hour: 30, minute: -5).save(defaults)
        XCTAssertEqual(DailyBriefSettings.load(defaults), DailyBriefSettings(enabled: true, hour: 23, minute: 0))
    }

    @MainActor
    func testATappedBriefNotificationOpensTheBrief() {
        XCTAssertTrue(DailyBriefScheduler.isBrief([DailyBriefScheduler.userInfoKey: true]))
        XCTAssertFalse(DailyBriefScheduler.isBrief([WorkflowScheduler.workflowIDKey: UUID().uuidString]))
        let router = DailyBriefRouter()
        router.open()
        XCTAssertTrue(router.pending)
    }

    @MainActor
    func testBriefMeIntentOpensTheBrief() async throws {
        DailyBriefRouter.shared.pending = false
        _ = try await BriefMeIntent().perform()
        XCTAssertTrue(DailyBriefRouter.shared.pending)
        DailyBriefRouter.shared.pending = false
        XCTAssertTrue(BriefMeIntent.openAppWhenRun)
    }
}

// MARK: - Screen questions

final class ScreenQuestionTests: XCTestCase {
    func testAHandedOverScreenshotWaitsInTheComposerWithItsQuestion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "screen-\(UUID().uuidString)"))
        let inbox = InboxStore(directory: dir)
        XCTAssertTrue(ScreenQuestion.handOver(Data([1, 2, 3]), question: "  ", inbox: inbox,
                                              directory: dir.appendingPathComponent("media"), defaults: defaults))
        let queued = inbox.drain()
        let name = try XCTUnwrap(queued.first?.attachments?.first)
        XCTAssertEqual(queued.first?.prompt, "", "it goes to the composer, not straight to a model")
        XCTAssertTrue(SharedMedia.isScreenshot(name), "masked as a screen whatever it looks like")
        XCTAssertEqual(SharedMedia.take(name, directory: dir.appendingPathComponent("media")), Data([1, 2, 3]))
        XCTAssertEqual(ScreenQuestion.consumeQuestion(defaults), ScreenQuestion.defaultQuestion)
        XCTAssertNil(ScreenQuestion.consumeQuestion(defaults), "one-shot")
    }

    func testPickerFlagIsOneShot() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "screen-\(UUID().uuidString)"))
        XCTAssertFalse(ScreenQuestion.consumePicker(defaults))
        ScreenQuestion.requestPicker(defaults)
        XCTAssertTrue(ScreenQuestion.consumePicker(defaults))
        XCTAssertFalse(ScreenQuestion.consumePicker(defaults))
    }

    func testSharedScreenshotsAreRecognisedByName() {
        XCTAssertTrue(SharedMedia.isScreenshot("\(UUID().uuidString)--Screenshot 2026-11-13 at 09.41.png"))
        XCTAssertTrue(SharedMedia.isScreenshot("\(UUID().uuidString)--Screen Shot 2020-01-01.png"))
        XCTAssertFalse(SharedMedia.isScreenshot("\(UUID().uuidString)--IMG_0001.HEIC"))
    }

    func testAForcedScreenIsMaskedEvenWhenItLooksLikeAPhoto() throws {
        // A square picture: not a screen's shape, so only `forceScreen` reads it as one.
        let size = 300
        let ctx = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try XCTUnwrap(ctx.makeImage())
        let data = try XCTUnwrap(PhotoPreparation.jpeg(image))
        XCTAssertFalse(ScreenSecrets.isScreenLike(data))
        XCTAssertNotNil(PhotoPreparation.prepare(data, forceScreen: true), "a forced screen still prepares")
    }
}
