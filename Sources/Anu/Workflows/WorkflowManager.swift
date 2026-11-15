import Foundation
import Combine
#if canImport(WidgetKit) && os(iOS)
import WidgetKit
#endif

extension Notification.Name {
    /// Posted when a workflow starts from inside the app, so screens covering
    /// the chat (the Settings sheet) get out of the way and the run is visible.
    static let anuShowChat = Notification.Name("com.anu.showChat")
}

/// Owns the saved-workflow list for the app UI. `@MainActor` ObservableObject
/// singleton, same shape as `ModelManager` / `ConnectorManager`. Persists through
/// `WorkflowStore` (App Group) so the widget and Shortcuts see edits immediately,
/// and keeps Spotlight, the widget and scheduled reminders in step.
@MainActor
final class WorkflowManager: ObservableObject {
    static let shared = WorkflowManager()

    @Published private(set) var workflows: [Workflow]
    /// True when a workflow has a schedule but notifications are not allowed,
    /// so its reminders will not appear.
    @Published private(set) var remindersBlocked = false

    private let store: WorkflowStore
    private let scheduler: (any WorkflowScheduling)?
    private let inbox: InboxStore
    private let now: () -> Date

    init(store: WorkflowStore = WorkflowStore(),
         scheduler: (any WorkflowScheduling)? = WorkflowManager.defaultScheduler(),
         inbox: InboxStore = InboxStore(),
         now: @escaping () -> Date = Date.init) {
        self.store = store
        self.scheduler = scheduler
        self.inbox = inbox
        self.now = now
        // Test isolation: `-reset_workflows YES` starts from empty (mirrors
        // -reset_conversation / -reset_connectors / -reset_privacy).
        if UserDefaults.standard.bool(forKey: "reset_workflows") {
            store.save([])
        }
        self.workflows = store.load()
        // Make saved workflows searchable in Spotlight / Siri Suggestions.
        SpotlightIndexer.shared.reindex(workflows)
        // Re-register reminders: pending notifications can be lost (restore,
        // reinstall) and the schedule on disk is the source of truth.
        resync()
    }

    nonisolated static func defaultScheduler() -> (any WorkflowScheduling)? {
        #if canImport(UserNotifications)
        return WorkflowScheduler()
        #else
        return nil
        #endif
    }

    func workflow(id: UUID) -> Workflow? {
        workflows.first { $0.id == id }
    }

    // MARK: - Editing

    @discardableResult
    func add(name: String, prompt: String, schedule: WorkflowSchedule? = nil) -> Workflow {
        let workflow = Workflow(name: name, prompt: prompt, schedule: schedule)
        workflows.append(workflow)
        persist()
        return workflow
    }

    func update(_ workflow: Workflow) {
        guard let idx = workflows.firstIndex(where: { $0.id == workflow.id }) else { return }
        var updated = workflow
        // Editing never rewinds the run history.
        updated.lastRunAt = workflow.lastRunAt ?? workflows[idx].lastRunAt
        workflows[idx] = updated
        persist()
    }

    /// A copy placed right after the original, unscheduled so one tap never
    /// doubles a reminder.
    @discardableResult
    func duplicate(id: UUID) -> Workflow? {
        guard let idx = workflows.firstIndex(where: { $0.id == id }) else { return nil }
        let copy = Workflow(name: "\(workflows[idx].name) copy", prompt: workflows[idx].prompt)
        workflows.insert(copy, at: idx + 1)
        persist()
        return copy
    }

    func delete(id: UUID) {
        workflows.removeAll { $0.id == id }
        persist()
    }

    func delete(at offsets: IndexSet) {
        workflows.remove(atOffsets: offsets)
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        workflows.move(fromOffsets: source, toOffset: destination)
        persist(reschedule: false)
    }

    // MARK: - Running

    /// Records that a run of `id` started. Called for every entry point: the
    /// in-app Run button, and inbox runs from Siri, the widget, Spotlight and
    /// reminders.
    func markRan(id: UUID) {
        guard let idx = workflows.firstIndex(where: { $0.id == id }) else { return }
        workflows[idx].lastRunAt = now()
        persist(reschedule: false)
    }

    /// Runs a workflow from inside the app, in the chat the user is looking at.
    func run(_ workflow: Workflow, orchestrator: AgentOrchestrator = .shared) {
        markRan(id: workflow.id)
        NotificationCenter.default.post(name: .anuShowChat, object: nil)
        Task { await orchestrator.run(userMessage: workflow.prompt) }
    }

    /// Queues a workflow for the inbox drain (the path shared with Siri and the
    /// widget). Used when the app is opened from a Spotlight result.
    @discardableResult
    func enqueueRun(id: UUID) -> Bool {
        guard let workflow = workflow(id: id) else { return false }
        inbox.enqueue(workflow.prompt, workflowID: workflow.id)
        NotificationCenter.default.post(name: .anuInboxUpdated, object: nil)
        return true
    }

    // MARK: - Persistence

    private func persist(reschedule: Bool = true) {
        store.save(workflows)
        SpotlightIndexer.shared.reindex(workflows)
        #if canImport(WidgetKit) && os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        if reschedule { resync() }
    }

    private func resync() {
        guard let scheduler else { return }
        let snapshot = workflows
        Task { [weak self] in
            let ok = await scheduler.sync(snapshot)
            self?.remindersBlocked = !ok
        }
    }
}
