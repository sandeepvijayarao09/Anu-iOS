import Foundation

extension Notification.Name {
    /// Posted (in-process) right after something enqueues an inbox request, so
    /// the app can drain immediately instead of waiting for the next activation.
    static let anuInboxUpdated = Notification.Name("com.anu.inboxUpdated")
}

/// One queued request to run in the app — from the widget, the share extension,
/// or a Siri/Shortcuts workflow run. Kept lightweight (just a prompt) so the
/// enqueuing code never needs the orchestrator.
struct InboxRequest: Codable, Sendable, Identifiable {
    let id: UUID
    let prompt: String

    init(id: UUID = UUID(), prompt: String) {
        self.id = id
        self.prompt = prompt
    }
}

/// A FIFO queue of pending prompts in the App Group container. Producers
/// (extensions / intents) `enqueue`; the app `drain`s on scene activation.
struct InboxStore {
    private let file: AppGroupFile<[InboxRequest]>

    init(directory: URL = AppGroup.containerURL) {
        self.file = AppGroupFile("inbox.json", directory: directory)
    }

    func enqueue(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var items = file.load() ?? []
        items.append(InboxRequest(prompt: trimmed))
        file.save(items)
    }

    /// Returns all pending requests and empties the queue.
    func drain() -> [InboxRequest] {
        let items = file.load() ?? []
        file.clear()
        return items
    }

    var isEmpty: Bool { (file.load() ?? []).isEmpty }
}
