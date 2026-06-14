import XCTest
@testable import GemmaAgent

@MainActor
final class WorkflowTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Store

    func testWorkflowStoreRoundTrip() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = WorkflowStore(directory: dir)
        XCTAssertTrue(store.load().isEmpty)
        store.save([Workflow(name: "Brief", prompt: "Summarize my unread mail")])
        let reloaded = WorkflowStore(directory: dir).load()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.name, "Brief")
    }

    // MARK: - Manager CRUD + persistence

    func testWorkflowManagerCRUD() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let manager = WorkflowManager(store: WorkflowStore(directory: dir))
        let wf = manager.add(name: "A", prompt: "do A")
        XCTAssertEqual(manager.workflows.count, 1)

        manager.update(Workflow(id: wf.id, name: "A2", prompt: "do A2"))
        XCTAssertEqual(manager.workflows.first?.name, "A2")

        // A fresh manager over the same store restores edits.
        XCTAssertEqual(WorkflowManager(store: WorkflowStore(directory: dir)).workflows.first?.prompt, "do A2")

        manager.delete(id: wf.id)
        XCTAssertTrue(manager.workflows.isEmpty)
    }

    // MARK: - Inbox queue

    func testInboxEnqueueDrainFIFOAndIgnoresBlank() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = InboxStore(directory: dir)
        XCTAssertTrue(inbox.isEmpty)
        inbox.enqueue("hello")
        inbox.enqueue("   ")          // blank ignored
        inbox.enqueue("world")
        let drained = inbox.drain()
        XCTAssertEqual(drained.map(\.prompt), ["hello", "world"])
        XCTAssertTrue(inbox.isEmpty)   // drain empties the queue
    }

    // MARK: - Intent → inbox (the widget / Siri / share path)

    func testRunWorkflowIntentEnqueuesPrompt() async throws {
        // RunWorkflowIntent writes to the default-container inbox; drain first
        // for isolation, then confirm the workflow's prompt was queued.
        _ = InboxStore().drain()
        let intent = RunWorkflowIntent(
            workflow: WorkflowEntity(id: UUID(), name: "X", prompt: "run the thing"))
        _ = try await intent.perform()
        XCTAssertEqual(InboxStore().drain().map(\.prompt), ["run the thing"])
    }

    // MARK: - Entity construction

    func testWorkflowEntityFromWorkflow() {
        let wf = Workflow(name: "Plan", prompt: "Plan my week")
        let entity = WorkflowEntity(wf)
        XCTAssertEqual(entity.id, wf.id)
        XCTAssertEqual(entity.name, "Plan")
        XCTAssertEqual(entity.prompt, "Plan my week")
    }
}
