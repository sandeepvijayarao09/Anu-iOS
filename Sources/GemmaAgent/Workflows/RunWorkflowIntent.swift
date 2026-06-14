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
    static let description = IntentDescription("Run a saved GemmaAgent workflow.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Workflow")
    var workflow: WorkflowEntity

    init() {}
    init(workflow: WorkflowEntity) { self.workflow = workflow }

    func perform() async throws -> some IntentResult {
        InboxStore().enqueue(workflow.prompt)
        NotificationCenter.default.post(name: .gemmaInboxUpdated, object: nil)
        return .result()
    }
}
