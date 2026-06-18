import Foundation

// MARK: - Memory scope

/// Whether a session reads/writes the shared, cross-session user memory.
/// A sandbox can opt out so nothing it discusses contaminates — or is
/// informed by — the global "about the user" notes.
enum MemoryScope: String, Codable, Sendable {
    case global    // default: read + write the shared MemoryStore
    case isolated  // sandbox: never touch global memory
}

// MARK: - Chat session (a "privacy sandbox")

/// One conversation sandbox — like a Gemini chat. Each has its own history
/// (stored under `sessions/<id>/`), its own memory scope, its own
/// privacy-ledger partition, and an optional per-session model override.
/// Metadata only; the messages live in a per-session `ConversationStore`.
struct ChatSession: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var name: String                 // auto-named from first user message; renamable
    let createdAt: Date
    var updatedAt: Date
    var ephemeral: Bool              // "incognito": cleared on background, not restored cold
    var memoryScope: MemoryScope
    var modelOverride: String?       // optional ModelOption id; nil = use the app default

    init(
        id: UUID = UUID(),
        name: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        ephemeral: Bool = false,
        memoryScope: MemoryScope = .global,
        modelOverride: String? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.ephemeral = ephemeral
        self.memoryScope = memoryScope
        self.modelOverride = modelOverride
    }
}

// MARK: - Session index

/// Lightweight on-disk index of every session plus the active one. Kept
/// separate from conversation bodies so the drawer loads instantly without
/// decoding every chat.
struct SessionIndex: Codable, Sendable {
    var sessions: [ChatSession]
    var activeSessionID: UUID?

    init(sessions: [ChatSession] = [], activeSessionID: UUID? = nil) {
        self.sessions = sessions
        self.activeSessionID = activeSessionID
    }
}
