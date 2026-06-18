import Foundation
import os

/// Owns the on-disk session index and vends a per-session `ConversationStore`.
/// Layout (Documents):
///   sessions/index.json                 — SessionIndex (metadata + activeSessionID)
///   sessions/<uuid>/conversation.json   — that session's ConversationStore.Snapshot
///
/// Same JSON-on-disk pattern as `ConversationStore`/`PrivacyLedgerStore`, with an
/// injectable `directory` so tests run against a temp dir.
struct SessionStore {
    private let sessionsDir: URL
    private let legacyConversationURL: URL

    init(directory: URL? = nil) {
        let docs = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.sessionsDir = docs.appendingPathComponent("sessions", isDirectory: true)
        self.legacyConversationURL = docs.appendingPathComponent("conversation.json")
    }

    private var indexURL: URL { sessionsDir.appendingPathComponent("index.json") }

    private static let log = Logger(subsystem: "com.anu.app", category: "SessionStore")

    // MARK: - Index

    func loadIndex() -> SessionIndex? {
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        return try? JSONDecoder().decode(SessionIndex.self, from: data)
    }

    func saveIndex(_ index: SessionIndex) {
        ensureSessionsDir()
        guard let data = try? JSONEncoder().encode(index) else { return }
        do {
            try data.write(to: indexURL, options: [.atomic, .completeFileProtection])
        } catch {
            Self.log.error("Failed to write session index: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Per-session conversation store

    /// A `ConversationStore` rooted in `sessions/<id>/`. Creates the directory so
    /// the store's atomic write can land. Reuses the existing 200-cap store
    /// verbatim — no signature change.
    func conversationStore(for id: UUID) -> ConversationStore {
        let dir = sessionsDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ConversationStore(directory: dir)
    }

    func deleteSession(id: UUID) {
        let dir = sessionsDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Wipes all sessions (used by the `-reset_sessions` launch arg).
    func clearAll() {
        try? FileManager.default.removeItem(at: sessionsDir)
    }

    // MARK: - Migration

    /// Returns the session index, creating it on first launch under the new
    /// model. If a legacy single-file `conversation.json` exists, it is folded
    /// into a "Session 1" sandbox so existing chats survive the upgrade.
    /// Idempotent: once an index exists this just loads it.
    func migrateLegacyConversationIfNeeded() -> SessionIndex {
        if let existing = loadIndex() { return existing }

        // index.json present but undecodable → corrupt. Don't overwrite it with a
        // fresh empty index (that silently drops recoverable session metadata):
        // back it up for inspection, log, and start clean alongside.
        if FileManager.default.fileExists(atPath: indexURL.path) {
            let backup = sessionsDir.appendingPathComponent("index.corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: indexURL, to: backup)
            Self.log.error("Session index unreadable — backed up to index.corrupt.json and starting fresh")
            let recovered = ChatSession(name: "New Chat")
            let index = SessionIndex(sessions: [recovered], activeSessionID: recovered.id)
            saveIndex(index)
            return index
        }

        var session = ChatSession(name: "New Chat")
        if let data = try? Data(contentsOf: legacyConversationURL),
           let snapshot = try? JSONDecoder().decode(ConversationStore.Snapshot.self, from: data),
           !snapshot.messages.isEmpty {
            session = ChatSession(name: "Session 1")
            conversationStore(for: session.id).save(messages: snapshot.messages,
                                                     history: snapshot.history)
            try? FileManager.default.removeItem(at: legacyConversationURL)
        }

        let index = SessionIndex(sessions: [session], activeSessionID: session.id)
        saveIndex(index)
        return index
    }

    private func ensureSessionsDir() {
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }
}
