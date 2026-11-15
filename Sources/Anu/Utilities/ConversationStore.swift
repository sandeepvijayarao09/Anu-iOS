import Foundation
import os

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
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        fileURL = dir.appendingPathComponent("conversation.json")
    }

    /// Caps prevent unbounded growth across many sessions — the UI list and
    /// the prompt window only ever need the recent past.
    static let maxStoredMessages = 200

    private static let log = Logger(subsystem: "com.anu.app", category: "ConversationStore")

    /// Saves run here, one at a time and in order, off the main thread:
    /// encoding and encrypting a chat with photos took long enough to
    /// stutter the UI at the end of a turn. Loads wait for pending saves.
    private static let queue = DispatchQueue(label: "com.anu.app.conversation-store", qos: .utility)

    func save(messages: [AgentMessage], history: [AgentMessage]) {
        let snapshot = Snapshot(
            messages: Array(messages.suffix(Self.maxStoredMessages)),
            history: Array(history.suffix(Self.maxStoredMessages))
        )
        let url = fileURL
        Self.queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            do {
                try SecureFile.write(data, to: url)
            } catch {
                Self.log.error("Failed to persist conversation: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Waits until every save asked for so far is on disk.
    static func flush() { queue.sync {} }

    func load() -> Snapshot? {
        Self.flush()
        guard let data = SecureFile.read(fileURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    func clear() {
        Self.flush()   // a pending save must not bring the chat back
        try? FileManager.default.removeItem(at: fileURL)
    }
}
