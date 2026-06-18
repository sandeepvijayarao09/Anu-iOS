import Foundation

/// Persists saved workflows as JSON in the App Group container so the app, the
/// widget, and the AppIntents query process all read the same list.
struct WorkflowStore {
    private let file: AppGroupFile<[Workflow]>

    init(directory: URL = AppGroup.containerURL) {
        self.file = AppGroupFile("workflows.json", directory: directory)
    }

    func load() -> [Workflow] { file.load() ?? [] }
    func save(_ workflows: [Workflow]) { file.save(workflows) }
}
