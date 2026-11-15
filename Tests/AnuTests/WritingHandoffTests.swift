import XCTest
@testable import Anu

/// The App Group hand-off between the writing extensions and the app: format,
/// one-per-source replacement, expiry, and the app-side runner on a mock and
/// the scripted model. No network anywhere.
@MainActor
final class WritingHandoffTests: XCTestCase {

    private func request(_ source: WritingHandoffSource = .keyboard, text: String = "hi there",
                         at date: Date = Date()) throws -> WritingHandoffRequest {
        WritingHandoffRequest(source: source, label: "Improve",
                              spec: try WritingPrompt.request(.improve, text: text),
                              original: text, meta: ["mode": "replaceBefore", "keep": "0", "action": "improve"],
                              createdAt: date)
    }

    func testRequestRoundTripsThroughJSON() throws {
        let r = try request()
        let data = try JSONEncoder().encode(r)
        XCTAssertEqual(try JSONDecoder().decode(WritingHandoffRequest.self, from: data), r)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for key in ["\"source\"", "\"spec\"", "\"system\"", "\"maxTokens\"", "\"original\"", "\"meta\""] {
            XCTAssertTrue(json.contains(key), key)
        }
    }

    func testOnePendingPerSourceAndTakeEmptiesTheQueue() throws {
        let store = WritingHandoffStore(directory: try tempDir())
        store.submit(try request(.keyboard, text: "first"))
        store.submit(try request(.keyboard, text: "second"))
        store.submit(try request(.writingExtension, text: "sheet"))
        XCTAssertTrue(store.isPending(.keyboard))
        let taken = store.takePending()
        XCTAssertEqual(Set(taken.map(\.original)), ["second", "sheet"])
        XCTAssertFalse(store.hasPending)
        XCTAssertTrue(store.takePending().isEmpty)
    }

    func testSubmitDropsAnOldResultFromTheSameSource() throws {
        let store = WritingHandoffStore(directory: try tempDir())
        let old = try request(text: "old")
        store.post(WritingHandoffResult(request: old, text: "Old.", failure: nil, engine: "Gemma"))
        store.submit(try request(text: "new"))
        XCTAssertNil(store.result(for: .keyboard))
    }

    func testEntriesExpireAfterTheLifetime() throws {
        let dir = try tempDir()
        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = WritingHandoffStore(directory: dir, now: { now })
        store.submit(try request(at: now))
        let r = try request(.writingExtension, at: now)
        store.post(WritingHandoffResult(request: r, text: "x", failure: nil, engine: "Gemma", createdAt: now))
        now = now.addingTimeInterval(WritingHandoffStore.lifetime - 1)
        XCTAssertTrue(store.hasPending)
        XCTAssertNotNil(store.result(for: .writingExtension))
        now = now.addingTimeInterval(2)
        XCTAssertFalse(store.hasPending)
        XCTAssertNil(store.result(for: .writingExtension))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(WritingHandoffStore.fileName).path),
                       "an empty store leaves no file behind")
    }

    func testConsumeDeletesTheResult() throws {
        let store = WritingHandoffStore(directory: try tempDir())
        let r = try request()
        store.post(WritingHandoffResult(request: r, text: "Done.", failure: nil, engine: "Gemma"))
        XCTAssertEqual(store.result(for: .keyboard)?.text, "Done.")
        store.consume(r.id)
        XCTAssertNil(store.result(for: .keyboard))
    }

    func testRunnerWritesCleanResultsAndShowsTheLatest() async throws {
        let store = WritingHandoffStore(directory: try tempDir())
        store.submit(try request(text: "fine words"))
        let runner = WritingHandoffRunner(store: store)
        let posted = await runner.process(with: MockEngine(["Sure! Here's the improved text:\nFiner words."]))
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(store.result(for: .keyboard)?.text, "Finer words.")
        XCTAssertEqual(store.result(for: .keyboard)?.engine, "Mock")
        XCTAssertEqual(runner.latest?.text, "Finer words.")
        XCTAssertFalse(store.hasPending)
    }

    func testRunnerTurnsMarkupIntoAFailure() async throws {
        let store = WritingHandoffStore(directory: try tempDir())
        store.submit(try request())
        let runner = WritingHandoffRunner(store: store)
        await runner.process(with: MockEngine([#"{"tool_call": {"name": "web_search"}}"#]))
        let result = try XCTUnwrap(store.result(for: .keyboard))
        XCTAssertNil(result.text)
        XCTAssertEqual(result.failure, "Anu couldn't do that on this device. Try again.")
    }

    func testRunnerDoesNothingWithAnEmptyQueue() async throws {
        let engine = MockEngine(["unused"])
        let runner = WritingHandoffRunner(store: WritingHandoffStore(directory: try tempDir()))
        let posted = await runner.process(with: engine)
        XCTAssertTrue(posted.isEmpty)
        XCTAssertTrue(engine.specs.isEmpty)
    }

    #if DEBUG
    func testRunnerOnTheScriptedModel() async throws {
        let store = WritingHandoffStore(directory: try tempDir())
        store.submit(try request(.writingExtension, text: "nice to meet you"))
        let runner = WritingHandoffRunner(store: store)
        await runner.process(with: LocalModelWritingEngine(model: ScriptedModel()))
        let result = try XCTUnwrap(store.result(for: .writingExtension))
        XCTAssertNotNil(result.text)
        XCTAssertEqual(result.engine, "Scripted Test Model")
    }
    #endif
}
