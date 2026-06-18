import AppIntents

/// Exposes saved workflows to Siri / Shortcuts so a user can pick one by name.
/// Reads from `WorkflowStore` (App Group) so it resolves correctly even when the
/// AppIntents query runs outside the main app process.
struct WorkflowEntity: AppEntity, Identifiable {
    let id: UUID
    let name: String
    let prompt: String

    init(id: UUID, name: String, prompt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
    }

    init(_ workflow: Workflow) {
        self.init(id: workflow.id, name: workflow.name, prompt: workflow.prompt)
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Workflow" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static var defaultQuery = WorkflowEntityQuery()
}

struct WorkflowEntityQuery: EntityQuery {
    func entities(for identifiers: [WorkflowEntity.ID]) async throws -> [WorkflowEntity] {
        WorkflowStore().load()
            .filter { identifiers.contains($0.id) }
            .map(WorkflowEntity.init)
    }

    func suggestedEntities() async throws -> [WorkflowEntity] {
        WorkflowStore().load().map(WorkflowEntity.init)
    }
}
