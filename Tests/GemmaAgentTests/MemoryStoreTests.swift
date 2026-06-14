import XCTest
@testable import GemmaAgent

@MainActor
final class MemoryStoreTests: XCTestCase {
    private var dir: URL!
    private var store: MemoryStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = MemoryStore(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAddEditDelete() {
        let note = store.add("My name is Sandeep")
        XCTAssertEqual(store.notes.count, 1)

        store.update(id: note.id, content: "My name is Sandeep Vijayarao")
        XCTAssertEqual(store.notes.first?.content, "My name is Sandeep Vijayarao")

        store.delete(id: note.id)
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testPersistenceRoundTrip() {
        store.add("I'm allergic to peanuts")
        let reloaded = MemoryStore(directory: dir)
        XCTAssertEqual(reloaded.notes.first?.content, "I'm allergic to peanuts")
    }

    func testRetrievalRanksRelevantNoteFirst() throws {
        store.add("My dog's name is Biscuit")
        store.add("I work as an iOS engineer in Boston")
        store.add("My favorite food is biryani")

        // "food" guarantees the token-overlap fallback also matches, so the
        // test is valid whether or not the embedding asset loads in this run
        let hits = store.retrieve(for: "what food should I cook for dinner tonight?")
        let top = try XCTUnwrap(hits.first, "food question should retrieve a memory")
        XCTAssertTrue(top.content.contains("biryani"),
                      "food memory should rank first, got: \(hits.map(\.content))")
    }

    func testRetrievalEmptyWhenIrrelevant() {
        store.add("My dog's name is Biscuit")
        let hits = store.retrieve(for: "explain general relativity's field equations")
        XCTAssertTrue(hits.allSatisfy { !$0.content.contains("relativity") })
    }

    func testGroundingBlockNumbersSources() {
        let notes = [MemoryNote(content: "fact one"), MemoryNote(content: "fact two")]
        let block = MemoryStore.groundingBlock(for: notes)
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("[M1] fact one"))
        XCTAssertTrue(block!.contains("[M2] fact two"))
        XCTAssertNil(MemoryStore.groundingBlock(for: []))
    }

    func testNoteCapEnforced() {
        for i in 0..<(MemoryStore.maxNotes + 10) {
            store.add("note \(i)")
        }
        XCTAssertEqual(store.notes.count, MemoryStore.maxNotes)
        XCTAssertEqual(store.notes.first?.content, "note \(MemoryStore.maxNotes + 9)", "newest kept")
    }

    func testContextIsAlwaysOnEvenForIrrelevantQueries() {
        store.add("My name is Sandeep")
        store.add("I prefer brief answers")

        // Topic has nothing to do with the saved facts — the personalization
        // layer must still carry them
        let (notes, block) = store.context(for: "write a poem about volcanoes")
        XCTAssertEqual(notes.count, 2)
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("Sandeep"))
        XCTAssertTrue(block!.contains("brief answers"))
    }

    func testContextMergesProfileAndRelevantWithoutDuplicates() {
        // 6 recent filler notes push the older food fact out of the profile tier
        store.add("My favorite food is biryani")
        for i in 0..<6 { store.add("filler note number \(i)") }

        let (notes, _) = store.context(for: "what food should I cook for dinner?")
        let ids = notes.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "no duplicate notes")
        XCTAssertTrue(notes.contains { $0.content.contains("biryani") },
                      "relevant older note must be pulled in by the relevance tier")
    }

    func testContextEmptyWhenNoMemories() {
        let (notes, block) = store.context(for: "anything")
        XCTAssertTrue(notes.isEmpty)
        XCTAssertNil(block)
    }

    // MARK: - "remember …" capture pattern

    func testRememberPatternExtraction() {
        XCTAssertEqual(AgentOrchestrator.rememberedFact(in: "remember that I love pizza"), "I love pizza")
        XCTAssertEqual(AgentOrchestrator.rememberedFact(in: "Remember my anniversary is June 5"), "my anniversary is June 5")
        XCTAssertNil(AgentOrchestrator.rememberedFact(in: "can you remember things?"), "mid-sentence mention is not a command")
        XCTAssertNil(AgentOrchestrator.rememberedFact(in: "remember "), "empty fact rejected")
    }

    func testChatTemplateIncludesGrounding() {
        let block = MemoryStore.groundingBlock(for: [MemoryNote(content: "user prefers brief answers")])
        let prompt = GemmaChatTemplate.formatChat(messages: [.user("hi")], memoryContext: block)
        XCTAssertTrue(prompt.contains("[M1] user prefers brief answers"))

        let agentPrompt = GemmaChatTemplate.format(messages: [.user("hi")], tools: [], memoryContext: block)
        XCTAssertTrue(agentPrompt.contains("[M1] user prefers brief answers"))
    }
}
