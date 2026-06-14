import Foundation
import Combine

/// Owns the saved-workflow list for the app UI. `@MainActor` ObservableObject
/// singleton, same shape as `ModelManager` / `ConnectorManager`. Persists through
/// `WorkflowStore` (App Group) so the widget and Shortcuts see edits immediately.
@MainActor
final class WorkflowManager: ObservableObject {
    static let shared = WorkflowManager()

    @Published private(set) var workflows: [Workflow]

    private let store: WorkflowStore

    init(store: WorkflowStore = WorkflowStore()) {
        self.store = store
        // Test isolation: `-reset_workflows YES` starts from empty (mirrors
        // -reset_conversation / -reset_connectors / -reset_privacy).
        if UserDefaults.standard.bool(forKey: "reset_workflows") {
            store.save([])
        }
        self.workflows = store.load()
    }

    @discardableResult
    func add(name: String, prompt: String) -> Workflow {
        let workflow = Workflow(name: name, prompt: prompt)
        workflows.append(workflow)
        persist()
        return workflow
    }

    func update(_ workflow: Workflow) {
        guard let idx = workflows.firstIndex(where: { $0.id == workflow.id }) else { return }
        workflows[idx] = workflow
        persist()
    }

    func delete(id: UUID) {
        workflows.removeAll { $0.id == id }
        persist()
    }

    func delete(at offsets: IndexSet) {
        workflows.remove(atOffsets: offsets)
        persist()
    }

    private func persist() { store.save(workflows) }
}
