import CryptoKit
import XCTest
@testable import Anu

/// A stand-in embedder that knows a few concepts, so search by meaning is
/// tested deterministically ("dinner" is close to "vegetarian").
private struct ConceptEmbedder: MemoryEmbedder {
    let id = "concepts.test"
    let closeEnough: Float = 0.5
    private static let concepts: [[String]] = [
        ["dinner", "lunch", "recipe", "restaurant", "vegetarian", "vegan", "diet", "food", "cook"],
        ["boss", "manager", "present", "gift", "work", "report"],
        ["run", "running", "marathon", "training", "fitness"],
        ["weather", "rain", "umbrella"],
    ]

    func embed(_ text: String) -> [Float]? {
        let words = MemoryNormalize.words(text)
        var v = [Float](repeating: 0.05, count: Self.concepts.count + 1)
        for (i, concept) in Self.concepts.enumerated() where words.contains(where: concept.contains) { v[i] += 1 }
        v[Self.concepts.count] = 0.2
        return v
    }
}

@MainActor
final class MemoryRelevanceTests: XCTestCase {
    private var dir: URL!
    private let keys = StaticDataKey(key: SymmetricKey(size: .bits256))

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("memory-relevance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func fact(_ predicate: String, _ value: String, subject: String = "user", origin: FactOrigin = .userStated,
                      sensitive: Bool = false) -> MemoryFact {
        MemoryFact(subject: subject, predicate: predicate, value: value, section: .identity, confidence: origin == .userStated ? 1 : 0.6,
                   origin: origin, sensitive: sensitive, firstSeen: Date(), sources: [])
    }

    private func store(with facts: [(String, String, String)], embedder: MemoryEmbedder?) -> MemoryStore {
        let store = MemoryStore(directory: dir, keys: keys, embedder: embedder)
        for (subject, predicate, value) in facts {
            let note = store.add("\(subject) \(predicate) \(value)")!
            store.learn([ExtractedFact(subject: subject, predicate: predicate, value: value, section: .identity, quote: value)],
                        from: note.sources[0])
        }
        return store
    }

    // MARK: By words

    func testPicksPeopleRelationsAndTopicsByWords() {
        let facts = [fact("manager", "Maya Chen"), fact("birthday", "12 March", subject: "Priya"), fact("likes", "climbing")]
        XCTAssertEqual(MemoryRelevance.pick("What should I get Priya?", facts: facts).map(\.value), ["12 March"])
        XCTAssertEqual(MemoryRelevance.pick("Email my manager", facts: facts).map(\.value), ["Maya Chen"])
        XCTAssertEqual(MemoryRelevance.pick("Find a climbing gym", facts: facts).map(\.value), ["climbing"])
    }

    func testGreetingsAndSmallNumbersMatchNothing() {
        let facts = [fact("meetings", "mornings"), fact("birthday", "12 March")]
        XCTAssertTrue(MemoryRelevance.pick("Good morning!", facts: facts).isEmpty)
        XCTAssertTrue(MemoryRelevance.pick("what is 12 times 7", facts: facts).isEmpty)
        XCTAssertFalse(MemoryRelevance.hasContent("Thanks!"))
    }

    func testPointsBackReadsThePreviousMessage() {
        let store = store(with: [("Priya", "birthday", "12 March")], embedder: nil)
        XCTAssertTrue(store.relevant(for: "and her favourite flowers?").isEmpty)
        XCTAssertEqual(store.relevant(for: "and her favourite flowers?", previous: "Plan something for Priya").map(\.value), ["12 March"])
        XCTAssertTrue(store.relevant(for: "what about tulips", previous: "Plan something for Priya").isEmpty,
                      "a message that doesn't point back is read on its own")
    }

    // MARK: By meaning

    func testFindsFactsByMeaningWithNoSharedWord() {
        let store = store(with: [("user", "diet", "vegetarian"), ("user", "manager", "Maya"), ("user", "likes", "marathon training")],
                          embedder: ConceptEmbedder())
        XCTAssertEqual(store.relevant(for: "Plan dinner for Saturday").map(\.value), ["vegetarian"])
        XCTAssertEqual(store.relevant(for: "Get a present for my boss").map(\.value), ["Maya"])
        XCTAssertTrue(store.relevant(for: "Will it rain tomorrow?").isEmpty, "nothing close in meaning")
    }

    func testWordsOnlyWithoutAnEmbedder() {
        let store = store(with: [("user", "diet", "vegetarian")], embedder: nil)
        XCTAssertTrue(store.relevant(for: "Plan dinner for Saturday").isEmpty)
        XCTAssertEqual(store.relevant(for: "Is my diet ok?").map(\.value), ["vegetarian"])
    }

    func testIndexingCatchesUpVectorsForANewEmbedder() async {
        _ = store(with: [("user", "diet", "vegetarian")], embedder: nil)
        let later = MemoryStore(directory: dir, keys: keys, embedder: ConceptEmbedder())
        XCTAssertTrue(later.relevant(for: "Plan dinner").isEmpty, "no vectors yet")
        let indexed = await later.indexVectors()
        XCTAssertEqual(indexed, 1)
        XCTAssertEqual(later.relevant(for: "Plan dinner").map(\.value), ["vegetarian"])
        let again = await later.indexVectors()
        XCTAssertEqual(again, 0)
    }

    func testHashingEmbedderIsDeterministicAndVectorsRoundTrip() throws {
        let a = try XCTUnwrap(HashingEmbedder().embed("My diet: vegetarian"))
        XCTAssertEqual(a, HashingEmbedder().embed("my DIET vegetarian!"))
        XCTAssertEqual(MemoryVectors.unpack(MemoryVectors.pack(a)), a)
        XCTAssertEqual(MemoryVectors.cosine(a, a), 1, accuracy: 0.0001)
        XCTAssertNil(HashingEmbedder().embed("thanks"))
    }

    // MARK: The memory block

    func testBlockPutsRelevantFactsFirstAndMarksUnconfirmedAndPrivate() throws {
        let store = MemoryStore(directory: dir, keys: keys, embedder: nil)
        let note = store.add("prefer brief answers")!
        _ = note
        let event = store.captureChat("My manager Maya and my allergy to peanuts")!
        store.learn([
            ExtractedFact(subject: "user", predicate: "manager", value: "Maya", section: .people, quote: "My manager Maya"),
            ExtractedFact(subject: "user", predicate: "allergic_to", value: "peanuts", section: .identity, quote: "allergy to peanuts", sensitive: true),
        ], from: event.id)
        let (used, block) = store.context(for: "Write a note to my manager")
        XCTAssertEqual(used.first?.value, "Maya", "relevant first")
        let text = try XCTUnwrap(block)
        XCTAssertTrue(text.contains("[M1] manager: Maya (learned, not yet confirmed)"))
        XCTAssertTrue(text.contains("allergic to: peanuts (learned, not yet confirmed, private)"))
        XCTAssertTrue(text.contains("prefer brief answers"), "the profile rides along whatever the topic")
    }

    func testBlockStaysWithinItsTokenBudget() {
        let store = MemoryStore(directory: dir, keys: keys, embedder: nil)
        for i in 0..<60 { store.add("note number \(i) with some extra words to take up room in the block") }
        let (used, block) = store.context(for: "hello there", tokenBudget: 200)
        XCTAssertLessThanOrEqual(block?.count ?? 0, 200 * 4 + 40)
        XCTAssertLessThan(used.count, 60)
        XCTAssertGreaterThan(used.count, 0)
    }

    // MARK: How facts read in the Memory screen

    func testFactWordsAndSearch() {
        XCTAssertEqual(MemoryFactWords.words(subject: "user", predicate: "manager", value: "maya Chen"),
                       MemoryFactWords(label: "Maya Chen", relationship: "Your manager"))
        XCTAssertEqual(MemoryFactWords.words(subject: "Priya", predicate: "lives_in", value: "Pune"),
                       MemoryFactWords(label: "Priya lives in Pune", relationship: nil))
        XCTAssertEqual(MemoryFactWords.words(subject: "Maya", predicate: "birthday", value: "12 March"),
                       MemoryFactWords(label: "12 March", relationship: "Maya's birthday"))
        XCTAssertEqual(MemoryFactWords.words(subject: "user", predicate: "is_vegetarian", value: "true").label, "Is vegetarian")
        let manager = fact("manager", "Maya Chen")
        XCTAssertTrue(MemoryFactWords.matches(manager, query: "your manager"))
        XCTAssertTrue(MemoryFactWords.matches(manager, query: "MAYA"))
        XCTAssertFalse(MemoryFactWords.matches(manager, query: "maya sister"))
        XCTAssertEqual(fact("likes", "tea", origin: .inferred).badge, .needsConfirming)
    }
}
