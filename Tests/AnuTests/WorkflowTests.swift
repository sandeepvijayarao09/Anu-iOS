import XCTest
@testable import Anu

@MainActor
final class WorkflowTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Store

    func testWorkflowStoreRoundTrip() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = WorkflowStore(directory: dir)
        XCTAssertTrue(store.load().isEmpty)
        store.save([Workflow(name: "Brief", prompt: "Summarize my unread mail")])
        let reloaded = WorkflowStore(directory: dir).load()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.name, "Brief")
    }

    // MARK: - Manager CRUD + persistence

    func testWorkflowManagerCRUD() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let manager = WorkflowManager(store: WorkflowStore(directory: dir), scheduler: nil)
        let wf = manager.add(name: "A", prompt: "do A")
        XCTAssertEqual(manager.workflows.count, 1)

        manager.update(Workflow(id: wf.id, name: "A2", prompt: "do A2"))
        XCTAssertEqual(manager.workflows.first?.name, "A2")

        // A fresh manager over the same store restores edits.
        XCTAssertEqual(WorkflowManager(store: WorkflowStore(directory: dir), scheduler: nil).workflows.first?.prompt, "do A2")

        manager.delete(id: wf.id)
        XCTAssertTrue(manager.workflows.isEmpty)
    }

    // MARK: - Inbox queue

    func testInboxEnqueueDrainFIFOAndIgnoresBlank() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = InboxStore(directory: dir)
        XCTAssertTrue(inbox.isEmpty)
        inbox.enqueue("hello")
        inbox.enqueue("   ")          // blank ignored
        inbox.enqueue("world")
        let drained = inbox.drain()
        XCTAssertEqual(drained.map(\.prompt), ["hello", "world"])
        XCTAssertTrue(inbox.isEmpty)   // drain empties the queue
    }

    // MARK: - Intent → inbox (the widget / Siri / share path)

    func testRunWorkflowIntentEnqueuesPrompt() async throws {
        // Use an isolated temp container: the hosted app's scene observer also
        // drains the *shared* App Group inbox on `.anuInboxUpdated`, so a
        // shared-container assertion is order-dependent (passes alone, flakes in
        // the full suite). Injecting the inbox keeps this test hermetic.
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = InboxStore(directory: dir)
        let intent = RunWorkflowIntent(
            workflow: WorkflowEntity(id: UUID(), name: "X", prompt: "run the thing"),
            inbox: inbox)
        _ = try await intent.perform()
        let drained = inbox.drain()
        XCTAssertEqual(drained.map(\.prompt), ["run the thing"])
        XCTAssertEqual(drained.first?.workflowID, intent.workflow.id)
    }

    // MARK: - Entity construction

    func testWorkflowEntityFromWorkflow() {
        let wf = Workflow(name: "Plan", prompt: "Plan my week")
        let entity = WorkflowEntity(wf)
        XCTAssertEqual(entity.id, wf.id)
        XCTAssertEqual(entity.name, "Plan")
        XCTAssertEqual(entity.prompt, "Plan my week")
    }

    // MARK: - Schedule

    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testScheduleTriggerComponents() {
        XCTAssertEqual(WorkflowSchedule(repeats: .daily, hour: 7, minute: 30).triggerComponents,
                       [DateComponents(hour: 7, minute: 30)])
        XCTAssertEqual(WorkflowSchedule(repeats: .weekdays, hour: 8).triggerComponents.map(\.weekday),
                       [2, 3, 4, 5, 6])
        XCTAssertEqual(WorkflowSchedule(repeats: .weekly, hour: 9, weekday: 1).triggerComponents,
                       [DateComponents(hour: 9, minute: 0, weekday: 1)])
    }

    func testScheduleClampsOutOfRangeValues() {
        let s = WorkflowSchedule(repeats: .weekly, hour: 30, minute: -5, weekday: 9)
        XCTAssertEqual(s.hour, 23)
        XCTAssertEqual(s.minute, 0)
        XCTAssertEqual(s.weekday, 7)
    }

    func testScheduleNextFireDate() {
        // 2026-10-02 is a Friday.
        let fridayNoon = date(2026, 10, 2, 12, 0)
        let daily = WorkflowSchedule(repeats: .daily, hour: 8)
        XCTAssertEqual(daily.nextFireDate(after: fridayNoon, calendar: utc), date(2026, 10, 3, 8, 0))
        // Weekdays skip the weekend: Friday noon → Monday 8:00.
        let weekdays = WorkflowSchedule(repeats: .weekdays, hour: 8)
        XCTAssertEqual(weekdays.nextFireDate(after: fridayNoon, calendar: utc), date(2026, 10, 5, 8, 0))
        // Later the same day still counts.
        let evening = WorkflowSchedule(repeats: .daily, hour: 18, minute: 15)
        XCTAssertEqual(evening.nextFireDate(after: fridayNoon, calendar: utc), date(2026, 10, 2, 18, 15))
        // Weekly on Sunday.
        let sunday = WorkflowSchedule(repeats: .weekly, hour: 10, weekday: 1)
        XCTAssertEqual(sunday.nextFireDate(after: fridayNoon, calendar: utc), date(2026, 10, 4, 10, 0))
    }

    func testScheduleSummary() {
        let en = Locale(identifier: "en_US")
        XCTAssertTrue(WorkflowSchedule(repeats: .weekdays, hour: 8).summary(calendar: utc, locale: en)
            .hasPrefix("Weekdays at 8:00"))
        XCTAssertTrue(WorkflowSchedule(repeats: .weekly, hour: 18, minute: 30, weekday: 2)
            .summary(calendar: utc, locale: en).hasPrefix("Mondays at 6:30"))
    }

    func testWorkflowSavedBeforeSchedulesStillDecodes() throws {
        let legacy = #"[{"id":"\#(UUID().uuidString)","name":"Old","prompt":"do it"}]"#
        let decoded = try JSONDecoder().decode([Workflow].self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.first?.name, "Old")
        XCTAssertNil(decoded.first?.schedule)
        XCTAssertNil(decoded.first?.lastRunAt)

        let legacyInbox = #"[{"id":"\#(UUID().uuidString)","prompt":"hi"}]"#
        let request = try JSONDecoder().decode([InboxRequest].self, from: Data(legacyInbox.utf8))
        XCTAssertNil(request.first?.workflowID)
    }

    // MARK: - Manager: runs, duplicate, schedule sync

    func testMarkRanAndEditKeepsHistory() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = WorkflowManager(store: WorkflowStore(directory: dir), scheduler: nil,
                                      inbox: InboxStore(directory: dir), now: { stamp })
        let wf = manager.add(name: "A", prompt: "do A")
        manager.markRan(id: wf.id)
        XCTAssertEqual(manager.workflow(id: wf.id)?.lastRunAt, stamp)
        // The editor passes lastRunAt nil for a fresh value; history survives.
        manager.update(Workflow(id: wf.id, name: "A2", prompt: "do A2"))
        XCTAssertEqual(manager.workflow(id: wf.id)?.lastRunAt, stamp)
        XCTAssertEqual(WorkflowStore(directory: dir).load().first?.lastRunAt, stamp)
    }

    func testDuplicateIsUnscheduledAndPlacedAfterOriginal() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let manager = WorkflowManager(store: WorkflowStore(directory: dir), scheduler: nil)
        let a = manager.add(name: "A", prompt: "do A", schedule: WorkflowSchedule(repeats: .daily))
        manager.add(name: "B", prompt: "do B")
        let copy = manager.duplicate(id: a.id)
        XCTAssertEqual(manager.workflows.map(\.name), ["A", "A copy", "B"])
        XCTAssertNil(copy?.schedule)
        XCTAssertEqual(copy?.prompt, "do A")
    }

    func testEnqueueRunQueuesWorkflowWithID() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = InboxStore(directory: dir)
        let manager = WorkflowManager(store: WorkflowStore(directory: dir), scheduler: nil, inbox: inbox)
        let wf = manager.add(name: "A", prompt: "do A")
        XCTAssertTrue(manager.enqueueRun(id: wf.id))
        XCTAssertFalse(manager.enqueueRun(id: UUID()))
        let drained = inbox.drain()
        XCTAssertEqual(drained.map(\.prompt), ["do A"])
        XCTAssertEqual(drained.first?.workflowID, wf.id)
    }

    func testSchedulerReplacesOnlyWorkflowReminders() async {
        let center = FakeNotificationCenter(pending: ["anu.workflow.old.0", "timer-123"])
        let scheduler = WorkflowScheduler(center: center)
        let weekdays = Workflow(name: "Brief", prompt: "p", schedule: WorkflowSchedule(repeats: .weekdays, hour: 8))
        let plain = Workflow(name: "Plain", prompt: "q")

        let ok = await scheduler.sync([weekdays, plain])
        XCTAssertTrue(ok)
        // Stale workflow reminders go; the timer tool's alert is untouched.
        XCTAssertEqual(center.removed, ["anu.workflow.old.0"])
        XCTAssertEqual(center.added.map(\.id), WorkflowScheduler.identifiers(for: weekdays))
        XCTAssertEqual(center.added.count, 5)
        XCTAssertTrue(center.added.allSatisfy { $0.workflowID == weekdays.id })
        // The prompt never reaches the lock screen.
        XCTAssertTrue(center.added.allSatisfy { $0.title == "Brief" && !$0.body.contains(weekdays.prompt + "\n") && $0.body != weekdays.prompt })
    }

    func testSchedulerReportsDeniedAndSkipsAuthWhenNothingScheduled() async {
        let center = FakeNotificationCenter(authorized: false)
        let scheduler = WorkflowScheduler(center: center)
        let ok = await scheduler.sync([Workflow(name: "P", prompt: "q")])
        XCTAssertTrue(ok)
        XCTAssertEqual(center.authRequests, 0)

        let denied = await scheduler.sync([Workflow(name: "S", prompt: "q", schedule: WorkflowSchedule())])
        XCTAssertFalse(denied)
        XCTAssertTrue(center.added.isEmpty)
    }

    func testNotificationTapQueuesItsWorkflow() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = WorkflowStore(directory: dir)
        let inbox = InboxStore(directory: dir)
        let wf = Workflow(name: "Brief", prompt: "brief me", schedule: WorkflowSchedule())
        store.save([wf])
        let info: [AnyHashable: Any] = [WorkflowScheduler.workflowIDKey: wf.id.uuidString]

        XCTAssertFalse(WorkflowNotificationHandler.enqueue(
            userInfo: info, actionIdentifier: "com.apple.UNNotificationDismissActionIdentifier",
            store: store, inbox: inbox))
        XCTAssertFalse(WorkflowNotificationHandler.enqueue(
            userInfo: [WorkflowScheduler.workflowIDKey: UUID().uuidString],
            actionIdentifier: WorkflowScheduler.runActionID, store: store, inbox: inbox))
        XCTAssertTrue(WorkflowNotificationHandler.enqueue(
            userInfo: info, actionIdentifier: WorkflowScheduler.runActionID, store: store, inbox: inbox))
        XCTAssertEqual(inbox.drain().map(\.workflowID), [wf.id])
    }
}

/// Records what the scheduler asks of the notification center.
private final class FakeNotificationCenter: WorkflowNotificationCenter, @unchecked Sendable {
    struct Added { let id: String; let title: String; let body: String; let workflowID: UUID }
    private let lock = NSLock()
    private var pending: [String]
    private let authorized: Bool
    private(set) var removed: [String] = []
    private(set) var added: [Added] = []
    private(set) var authRequests = 0

    init(pending: [String] = [], authorized: Bool = true) {
        self.pending = pending
        self.authorized = authorized
    }

    func requestAuthorization() async -> Bool {
        lock.withLock { authRequests += 1 }
        return authorized
    }

    func pendingIdentifiers() async -> [String] { lock.withLock { pending } }

    func removePending(identifiers: [String]) {
        lock.withLock {
            removed += identifiers
            pending.removeAll { identifiers.contains($0) }
        }
    }

    func add(identifier: String, title: String, body: String,
             components: DateComponents, workflowID: UUID) async {
        lock.withLock {
            added.append(Added(id: identifier, title: title, body: body, workflowID: workflowID))
            pending.append(identifier)
        }
    }
}
