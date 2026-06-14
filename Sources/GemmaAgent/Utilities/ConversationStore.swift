import Foundation

/// Persists the conversation to disk so chats survive app restarts
/// (and iOS evicting the suspended app from memory).
struct ConversationStore {

    struct Snapshot: Codable {
        let messages: [AgentMessage]
        let history: [AgentMessage]
    }

    private let fileURL: URL

    init(directory: URL? = nil) {
        let dir = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("conversation.json")
    }

    /// Caps prevent unbounded growth across many sessions — the UI list and
    /// the prompt window only ever need the recent past.
    static let maxStoredMessages = 200

    func save(messages: [AgentMessage], history: [AgentMessage]) {
        let snapshot = Snapshot(
            messages: Array(messages.suffix(Self.maxStoredMessages)),
            history: Array(history.suffix(Self.maxStoredMessages))
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
