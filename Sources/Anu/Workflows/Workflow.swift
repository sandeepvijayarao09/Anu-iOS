import Foundation

/// A saved, re-runnable recipe: a name plus the prompt the agent runs. Connectors
/// are configured globally and already available to the agent loop, so a
/// workflow's "recipe" is simply its prompt — no hidden global-state mutation.
struct Workflow: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var name: String
    var prompt: String

    init(id: UUID = UUID(), name: String, prompt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
    }
}
