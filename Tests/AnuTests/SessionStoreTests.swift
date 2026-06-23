import XCTest
@testable import Anu

/// Covers the session index + per-session conversation isolation + migration.
final class SessionStoreTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testCreateAndLoadIndex() {
        let store = SessionStore(directory: tempDir())
        let session = ChatSession(name: "Alpha")
        store.saveIndex(SessionIndex(sessions: [session], activeSessionID: session.id))

        let loaded = store.loadIndex()
        XCTAssertEqual(loaded?.sessions.count, 1)
        XCTAssertEqual(loaded?.sessions.first?.name, "Alpha")
        XCTAssertEqual(loaded?.activeSessionID, session.id)
    }

    func testPerSessionConversationsAreIsolated() {
        let store = SessionStore(directory: tempDir())
        let a = UUID(), b = UUID()
        store.conversationStore(for: a).save(messages: [.user("in A")], history: [.user("in A")])
        store.conversationStore(for: b).save(messages: [.user("in B")], history: [.user("in B")])

        XCTAssertEqual(store.conversationStore(for: a).load()?.messages.first?.content, "in A")
        XCTAssertEqual(store.conversationStore(for: b).load()?.messages.first?.content, "in B")
    }

    func testDeleteSessionRemovesItsConversation() {
        let store = SessionStore(directory: tempDir())
        let id = UUID()
        store.conversationStore(for: id).save(messages: [.user("hi")], history: [])
        XCTAssertNotNil(store.conversationStore(for: id).load())

        store.deleteSession(id: id)
        XCTAssertNil(store.conversationStore(for: id).load())
    }

    func testClearAllRemovesEverything() {
        let store = SessionStore(directory: tempDir())
        let session = ChatSession(name: "X")
        store.saveIndex(SessionIndex(sessions: [session], activeSessionID: session.id))
        store.conversationStore(for: session.id).save(messages: [.user("hi")], history: [])

        store.clearAll()
        XCTAssertNil(store.loadIndex())
    }

    func testMigratesLegacyConversation() {
        let dir = tempDir()
        // Seed a legacy single-file conversation.json in the base dir.
        ConversationStore(directory: dir).save(messages: [.user("old chat")],
                                               history: [.user("old chat")])

        let store = SessionStore(directory: dir)
        let index = store.migrateLegacyConversationIfNeeded()
        XCTAssertEqual(index.sessions.count, 1)
        XCTAssertEqual(index.sessions.first?.name, "Session 1")
        let activeID = try! XCTUnwrap(index.activeSessionID)
        XCTAssertEqual(store.conversationStore(for: activeID).load()?.messages.first?.content,
                       "old chat")

        // Idempotent: a second call returns the same index, no new session.
        let again = store.migrateLegacyConversationIfNeeded()
        XCTAssertEqual(again.sessions.count, 1)
        XCTAssertEqual(again.activeSessionID, activeID)
    }

    func testMigrationWithNoLegacyCreatesEmptyDefault() {
        let store = SessionStore(directory: tempDir())
        let index = store.migrateLegacyConversationIfNeeded()
        XCTAssertEqual(index.sessions.count, 1)
        XCTAssertEqual(index.sessions.first?.name, "New Chat")
        XCTAssertNotNil(index.activeSessionID)
    }

    func testMigratesLegacyHistoryOnlyConversation() {
        let dir = tempDir()
        // A legacy conversation with NO display messages but non-empty context
        // history used to be dropped on the rename migration.
        ConversationStore(directory: dir).save(messages: [], history: [.user("prior context")])

        let store = SessionStore(directory: dir)
        let index = store.migrateLegacyConversationIfNeeded()
        XCTAssertEqual(index.sessions.first?.name, "Session 1",
                       "history-only legacy conversation should still migrate")
        let activeID = try! XCTUnwrap(index.activeSessionID)
        XCTAssertEqual(store.conversationStore(for: activeID).load()?.history.first?.content,
                       "prior context")
    }
}
