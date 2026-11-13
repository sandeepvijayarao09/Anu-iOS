import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Keeps the system's pending notifications in step with the workflows'
/// schedules. The manager calls `sync` after every change; it returns false when
/// something is scheduled but notifications are not allowed.
@MainActor
protocol WorkflowScheduling: AnyObject {
    func sync(_ workflows: [Workflow]) async -> Bool
}

/// The slice of `UNUserNotificationCenter` the scheduler uses. Injectable so the
/// identifier and trigger logic is testable without touching the real center.
protocol WorkflowNotificationCenter: Sendable {
    func requestAuthorization() async -> Bool
    func pendingIdentifiers() async -> [String]
    func removePending(identifiers: [String])
    func add(identifier: String, title: String, body: String,
             components: DateComponents, workflowID: UUID) async
}

/// Schedules a repeating reminder for each scheduled workflow. Tapping it (or
/// its Run button) runs the workflow — see `WorkflowNotificationHandler`.
///
/// Why a notification and not a background run: iOS gives no guaranteed
/// background time at a set hour, and loading a multi-GB on-device model
/// in a background task is not reliable. So a scheduled workflow runs when
/// the user taps its reminder, in the foreground, with approvals and
/// receipts as usual. It is never an unattended run.
@MainActor
final class WorkflowScheduler: WorkflowScheduling {
    static let identifierPrefix = "anu.workflow."
    static let categoryID = "anu.workflow"
    static let runActionID = "anu.workflow.run"
    static let workflowIDKey = "workflowID"

    private let center: any WorkflowNotificationCenter
    /// Syncs run one at a time so a quick edit cannot interleave with the last.
    private var last: Task<Bool, Never>?

    nonisolated init(center: any WorkflowNotificationCenter) {
        self.center = center
    }

    #if canImport(UserNotifications)
    nonisolated convenience init() { self.init(center: SystemWorkflowNotificationCenter()) }
    #endif

    /// Notification ids for a workflow, one per trigger ("anu.workflow.<id>.<n>").
    static func identifiers(for workflow: Workflow) -> [String] {
        guard let schedule = workflow.schedule else { return [] }
        return schedule.triggerComponents.indices.map {
            "\(identifierPrefix)\(workflow.id.uuidString).\($0)"
        }
    }

    func sync(_ workflows: [Workflow]) async -> Bool {
        let previous = last
        let task = Task { [center] () -> Bool in
            _ = await previous?.value
            // Replace the whole set: cheap, and it drops reminders for deleted
            // or unscheduled workflows without tracking diffs.
            let stale = await center.pendingIdentifiers().filter { $0.hasPrefix(Self.identifierPrefix) }
            center.removePending(identifiers: stale)

            let scheduled = workflows.filter { $0.schedule != nil }
            guard !scheduled.isEmpty else { return true }
            guard await center.requestAuthorization() else { return false }
            for workflow in scheduled {
                guard let schedule = workflow.schedule else { continue }
                for (id, comps) in zip(Self.identifiers(for: workflow), schedule.triggerComponents) {
                    // The prompt stays off the lock screen, as it stays out of
                    // Spotlight; only the name is shown.
                    await center.add(identifier: id, title: workflow.name,
                                     body: "Tap to run this workflow in Anu.",
                                     components: comps, workflowID: workflow.id)
                }
            }
            return true
        }
        last = task
        return await task.value
    }
}

#if canImport(UserNotifications)
/// The real notification center.
struct SystemWorkflowNotificationCenter: WorkflowNotificationCenter {
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func pendingIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier)
    }

    func removePending(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func add(identifier: String, title: String, body: String,
             components: DateComponents, workflowID: UUID) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = WorkflowScheduler.categoryID
        content.userInfo = [WorkflowScheduler.workflowIDKey: workflowID.uuidString]
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Receives taps on workflow reminders. Installed at launch (before the app
/// finishes launching, so a tap that cold-starts the app is not lost). A tap
/// only queues the workflow; the app's normal inbox drain runs it.
final class WorkflowNotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WorkflowNotificationHandler()

    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let run = UNNotificationAction(identifier: WorkflowScheduler.runActionID,
                                       title: "Run", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: WorkflowScheduler.categoryID,
                                   actions: [run], intentIdentifiers: [], options: [])
        ])
    }

    /// Queues the workflow a notification points at. Returns false when the
    /// notification is not a workflow reminder, or its workflow was deleted.
    @discardableResult
    static func enqueue(userInfo: [AnyHashable: Any], actionIdentifier: String,
                        store: WorkflowStore = WorkflowStore(),
                        inbox: InboxStore = InboxStore()) -> Bool {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier
                || actionIdentifier == WorkflowScheduler.runActionID,
              let raw = userInfo[WorkflowScheduler.workflowIDKey] as? String,
              let id = UUID(uuidString: raw),
              let workflow = store.load().first(where: { $0.id == id }) else { return false }
        inbox.enqueue(workflow.prompt, workflowID: workflow.id)
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        guard Self.enqueue(userInfo: content.userInfo,
                           actionIdentifier: response.actionIdentifier) else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: .anuInboxUpdated, object: nil)
        }
    }

    /// Show reminders (and timer alerts) even while Anu is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
#endif
