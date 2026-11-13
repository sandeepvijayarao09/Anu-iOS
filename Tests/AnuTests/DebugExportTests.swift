#if DEBUG
import XCTest
@testable import Anu

/// The DEBUG-only chat export (Settings → Developer).
@MainActor
final class DebugExportTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("debugexport-\(UUID().uuidString)")
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testExportsEverySessionsMessagesWithoutPhotoBytes() throws {
        let sessions = SessionStore(directory: dir.appendingPathComponent("sessions"))
        let chat = ChatSession(name: "Paris trip")
        sessions.saveIndex(SessionIndex(sessions: [chat], activeSessionID: chat.id))
        let photo = Data(repeating: 0xAB, count: 50_000)
        var answer = AgentMessage.assistant("Paris is the capital of France.")
        answer.label = "On device · no model needed"
        let question = AgentMessage(role: .user, content: "What's the capital of France?", photos: [photo])
        sessions.conversationStore(for: chat.id).save(messages: [question, answer], history: [question, answer])

        let export = DebugExport.build(sessions: sessions, memory: [], ledger: [], activity: [])
        XCTAssertEqual(export.chats.count, 1)
        XCTAssertEqual(export.chats[0].name, "Paris trip")
        XCTAssertEqual(export.chats[0].messages.map(\.content),
                       ["What's the capital of France?", "Paris is the capital of France."])
        XCTAssertEqual(export.chats[0].messages[0].photoCount, 1)
        XCTAssertEqual(export.chats[0].messages[1].label, "On device · no model needed")

        let out = dir.appendingPathComponent("out")
        let result = try DebugExport.write(export, to: out)
        XCTAssertEqual(result.chats, 1)
        XCTAssertEqual(result.messages, 2)
        XCTAssertLessThan(result.bytes, 10_000, "photo bytes must not be in the export")
        let text = try String(contentsOf: result.url, encoding: .utf8)
        XCTAssertTrue(text.contains("Paris is the capital of France."), "the export is plain text")
        XCTAssertFalse(SecureFile.isEncrypted(result.url))
        XCTAssertEqual(try result.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

        XCTAssertTrue(DebugExport.exists(in: out))
        DebugExport.delete(in: out)
        XCTAssertFalse(DebugExport.exists(in: out))
    }

    func testNoSessionsGivesAnEmptyExport() {
        let export = DebugExport.build(sessions: SessionStore(directory: dir), memory: [], ledger: [], activity: [])
        XCTAssertTrue(export.chats.isEmpty)
    }
}
#endif
