import Foundation

/// A saved, re-runnable recipe: a name plus the prompt the agent runs. Connectors
/// are configured globally and already available to the agent loop, so a
/// workflow's "recipe" is simply its prompt — no hidden global-state mutation.
///
/// `schedule` and `lastRunAt` are optional so workflows saved before they
/// existed still decode (synthesized `Decodable` uses `decodeIfPresent`).
struct Workflow: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var name: String
    var prompt: String
    /// When set, Anu reminds the user to run it at this time (see
    /// `WorkflowScheduler`). Nil = run on demand only.
    var schedule: WorkflowSchedule?
    /// The last time a run of this workflow started, from any entry point.
    var lastRunAt: Date?

    init(id: UUID = UUID(), name: String, prompt: String,
         schedule: WorkflowSchedule? = nil, lastRunAt: Date? = nil) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.schedule = schedule
        self.lastRunAt = lastRunAt
    }
}
