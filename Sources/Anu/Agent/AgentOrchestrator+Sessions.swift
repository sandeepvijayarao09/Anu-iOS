import Foundation

// Session lifecycle & persistence, split out of the AgentOrchestrator core.
extension AgentOrchestrator {
    // MARK: - Session lifecycle

    func listSessions() -> [ChatSession] { sessions }

    /// Loads the session index from disk, restores the active sandbox's
    /// conversation, and points the privacy ledger at it. Synchronous (cheap
    /// file IO) so it can run inline in `setup()` before model load.
    func loadActiveSessionFromDisk() {
        let index = sessionStore.migrateLegacyConversationIfNeeded()
        sessions = index.sessions.sorted { $0.updatedAt > $1.updatedAt }
        let activeID = index.activeSessionID ?? sessions.first?.id
        activeSessionID = activeID
        guard let activeID else { return }
        PrivacyLedger.shared.setActiveSession(activeID)
        if let saved = sessionStore.conversationStore(for: activeID).load() {
            messages = saved.messages
            conversationHistory = saved.history
        }
    }

    /// Ephemeral sandboxes are "incognito" — deleted on cold start. Always leaves
    /// exactly one active session behind.
    func sweepEphemeralSessions() {
        let ephemeral = sessions.filter { $0.ephemeral }
        guard !ephemeral.isEmpty else { return }
        for session in ephemeral {
            sessionStore.deleteSession(id: session.id)
            PrivacyLedger.shared.clearSession(session.id)
        }
        sessions.removeAll { $0.ephemeral }
        if activeSessionID == nil || !sessions.contains(where: { $0.id == activeSessionID }) {
            let fresh = ChatSession(name: "New Chat")
            sessions.insert(fresh, at: 0)
            activeSessionID = fresh.id
            messages = []
            conversationHistory = []
            reasoningSteps = []
            PrivacyLedger.shared.setActiveSession(fresh.id)
        }
        persistIndex()
    }

    /// Guarantees there is an active session, creating one if needed. Idempotent.
    @discardableResult
    func ensureActiveSession() -> UUID {
        if let id = activeSessionID { return id }
        loadActiveSessionFromDisk()
        if let id = activeSessionID { return id }
        let fresh = ChatSession(name: "New Chat")
        sessions = [fresh]
        activeSessionID = fresh.id
        PrivacyLedger.shared.setActiveSession(fresh.id)
        persistIndex()
        return fresh.id
    }

    /// Creates a new sandbox and switches to it. Persists the outgoing one first.
    @discardableResult
    func createSession(name: String = "New Chat",
                       ephemeral: Bool = false,
                       memoryScope: MemoryScope = .global) -> UUID {
        persistActive()
        let session = ChatSession(name: name, ephemeral: ephemeral, memoryScope: memoryScope)
        sessions.insert(session, at: 0)
        activeSessionID = session.id
        messages = []
        conversationHistory = []
        reasoningSteps = []
        status = .idle
        PrivacyLedger.shared.setActiveSession(session.id)
        Task { await model.resetSession() }
        persistIndex()
        return session.id
    }

    /// Switches the loaded conversation to another sandbox.
    func switchSession(to id: UUID) async {
        guard !isThinking else {
            addSystemMessage("Finish or stop the current reply before switching chats.")
            return
        }
        guard id != activeSessionID else { return }
        persistActive()
        activeSessionID = id
        let saved = sessionStore.conversationStore(for: id).load()
        messages = saved?.messages ?? []
        conversationHistory = saved?.history ?? []
        reasoningSteps = []
        status = .idle
        PrivacyLedger.shared.setActiveSession(id)
        await model.resetSession()    // don't let one sandbox's KV cache leak into another
        persistIndex()
    }

    func renameSession(id: UUID, name: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessions[idx].name = trimmed
        sessions[idx].updatedAt = Date()
        persistIndex()
    }

    func deleteSession(id: UUID) async {
        guard !isThinking else {
            addSystemMessage("Finish or stop the current reply before deleting a chat.")
            return
        }
        sessionStore.deleteSession(id: id)
        PrivacyLedger.shared.clearSession(id)
        sessions.removeAll { $0.id == id }

        if activeSessionID == id {
            if let next = sessions.first {
                activeSessionID = next.id
                let saved = sessionStore.conversationStore(for: next.id).load()
                messages = saved?.messages ?? []
                conversationHistory = saved?.history ?? []
                PrivacyLedger.shared.setActiveSession(next.id)
            } else {
                let fresh = ChatSession(name: "New Chat")
                sessions = [fresh]
                activeSessionID = fresh.id
                messages = []
                conversationHistory = []
                PrivacyLedger.shared.setActiveSession(fresh.id)
            }
            reasoningSteps = []
            status = .idle
            await model.resetSession()
        }
        persistIndex()
    }

    func setEphemeral(_ ephemeral: Bool, for id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].ephemeral = ephemeral
        persistIndex()
    }

    func setMemoryScope(_ scope: MemoryScope, for id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].memoryScope = scope
        persistIndex()
    }

    /// Clears the active conversation if it's an ephemeral sandbox (called when
    /// the app backgrounds). The privacy ledger is independent and untouched here.
    func clearActiveIfEphemeral() {
        guard let session = activeSession, session.ephemeral else { return }
        messages = []
        conversationHistory = []
        reasoningSteps = []
        activeStore.clear()
    }

    // MARK: - Session persistence helpers

    func persistActive() {
        guard let id = activeSessionID else { return }
        sessionStore.conversationStore(for: id).save(messages: messages, history: conversationHistory)
    }

    func persistIndex() {
        sessionStore.saveIndex(SessionIndex(sessions: sessions, activeSessionID: activeSessionID))
    }

    /// Bumps the active sandbox's `updatedAt` and floats it to the top of the
    /// drawer after a completed turn.
    func touchActiveSession() {
        guard let id = activeSessionID,
              let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].updatedAt = Date()
        let session = sessions.remove(at: idx)
        sessions.insert(session, at: 0)
        persistIndex()
    }

    /// First user turn of a still-default-named sandbox → name it from the message.
    func autoNameIfNeeded(from userMessage: String) {
        guard let id = activeSessionID,
              let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let isFirstUserTurn = conversationHistory.filter { $0.role == .user }.count == 1
        guard isFirstUserTurn, sessions[idx].name == "New Chat" else { return }
        let trimmed = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessions[idx].name = trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
        persistIndex()
    }

}
