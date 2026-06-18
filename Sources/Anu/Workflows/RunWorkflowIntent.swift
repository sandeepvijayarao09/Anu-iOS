import AppIntents
import Foundation

/// Runs a saved workflow from Siri / Shortcuts / the Action Button / a widget
/// button. Deliberately lightweight: it only enqueues the workflow's prompt into
/// the App Group inbox and posts an in-process nudge — it never references the
/// orchestrator, so the SAME type compiles into the widget extension without
/// dragging in the model stack. `openAppWhenRun` brings the app forward, which
/// drains the inbox and runs the prompt through the normal pipeline.
struct RunWorkflowIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Workflow"
    static let description = IntentDescription("Run a saved Anu workflow.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Workflow")
    var workflow: WorkflowEntity

    /// Inbox to enqueue into. Injectable so tests can target an isolated
    /// container — the running app's scene observer also drains the shared
    /// App Group inbox on `.anuInboxUpdated`, which makes a shared-container
    /// assertion order-dependent.
    private let inbox: InboxStore

    init() { self.inbox = InboxStore() }
    init(workflow: WorkflowEntity, inbox: InboxStore = InboxStore()) {
        // `inbox` must be set before the @Parameter-wrapped `workflow`
        // assignment, which reads `self`.
        self.inbox = inbox
        self.workflow = workflow
    }

    func perform() async throws -> some IntentResult {
        inbox.enqueue(workflow.prompt)
        NotificationCenter.default.post(name: .anuInboxUpdated, object: nil)
        return .result()
    }
}
