import Foundation
import NaturalLanguage

// Retrieval for Memory v2 (Android ADR-054, ADR-055, ADR-056): the facts that
// bear on a message, by the words they share and by closeness in meaning.

// MARK: - Embedders

/// Turns text into a vector for search by meaning. Runs on this device only.
protocol MemoryEmbedder: Sendable {
    /// Names the model, so vectors from another one are rebuilt.
    var id: String { get }
    /// How close (cosine) a fact must be to count by meaning alone.
    var closeEnough: Float { get }
    func embed(_ text: String) -> [Float]?
}

enum MemoryEmbedders {
    /// The best embedder this device has without downloading anything:
    /// Apple's contextual embedding when its assets are already installed,
    /// else the built-in sentence embedding, else none (words only).
    /// Nothing here requests an asset download, so retrieval never causes
    /// network egress.
    static func onDevice() -> MemoryEmbedder? {
        ContextualSentenceEmbedder.make() ?? SentenceEmbedder.make()
    }
}

/// `NLContextualEmbedding` (iOS 17, macOS 14), mean-pooled over tokens.
final class ContextualSentenceEmbedder: MemoryEmbedder, @unchecked Sendable {
    let id: String
    /// Mean-pooled contextual vectors sit close together; the stands-out test
    /// in `MemoryRelevance` does most of the work. Not tuned on a device yet.
    let closeEnough: Float = 0.55
    private let embedding: NLContextualEmbedding
    private let lock = NSLock()
    private var loaded = false

    private init(_ embedding: NLContextualEmbedding) {
        self.embedding = embedding
        self.id = "nl.contextual.\(embedding.modelIdentifier).r\(embedding.revision)"
    }

    static func make() -> ContextualSentenceEmbedder? {
        guard let embedding = NLContextualEmbedding(language: .english), embedding.hasAvailableAssets else { return nil }
        return ContextualSentenceEmbedder(embedding)
    }

    func embed(_ text: String) -> [Float]? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        return lock.withLock {
            do {
                if !loaded { try embedding.load(); loaded = true }
                let result = try embedding.embeddingResult(for: input, language: .english)
                var sum = [Double](repeating: 0, count: embedding.dimension)
                var count = 0
                result.enumerateTokenVectors(in: input.startIndex..<input.endIndex) { vector, _ in
                    for i in 0..<min(vector.count, sum.count) { sum[i] += vector[i] }
                    count += 1
                    return true
                }
                guard count > 0 else { return nil }
                return sum.map { Float($0 / Double(count)) }
            } catch {
                return nil
            }
        }
    }
}

/// `NLEmbedding.sentenceEmbedding` — what earlier builds used.
final class SentenceEmbedder: MemoryEmbedder, @unchecked Sendable {
    let id: String
    let closeEnough: Float = 0.30
    private let embedding: NLEmbedding
    private let lock = NSLock()

    private init(_ embedding: NLEmbedding) {
        self.embedding = embedding
        self.id = "nl.sentence.en.r\(embedding.revision)"
    }

    static func make() -> SentenceEmbedder? {
        NLEmbedding.sentenceEmbedding(for: .english).map(SentenceEmbedder.init)
    }

    func embed(_ text: String) -> [Float]? {
        lock.withLock { embedding.vector(for: text.lowercased())?.map(Float.init) }
    }
}

/// Deterministic bag-of-words vectors (feature hashing over the content words
/// `MemoryRelevance` reads). For tests and as a model-free fallback: it finds
/// shared words, never meaning.
struct HashingEmbedder: MemoryEmbedder {
    var id = "hashing.v1"
    var closeEnough: Float = 0.30
    var dimension = 256

    func embed(_ text: String) -> [Float]? {
        let words = MemoryRelevance.contentWords(text)
        guard !words.isEmpty else { return nil }
        var v = [Float](repeating: 0, count: dimension)
        for word in words {
            var hash: UInt64 = 0xcbf29ce484222325   // FNV-1a: stable across launches
            for byte in word.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            v[Int(hash % UInt64(dimension))] += (hash >> 63) == 0 ? 1 : -1
        }
        return v
    }
}

enum MemoryVectors {
    static func pack(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func unpack(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom > 0 ? dot / denom : -1
    }
}

// MARK: - Relevance

/// Picks the facts that bear on a message: people it names, relations and
/// topics it shares with a fact and, with an embedder, facts close to it in
/// meaning though they share no word ("plan dinner" and "diet: vegetarian").
enum MemoryRelevance {
    static let limit = 8
    static let budgetChars = 600
    /// A fact counts by meaning alone when it stands out from the message's
    /// other facts by this many standard deviations (ADR-056)…
    static let standsOut: Float = 1.25
    /// …once there are this many facts to compare; below it, closeness alone decides.
    private static let spreadFrom = 5
    /// How much closeness counts beside word matches.
    private static let meaningWeight: Float = 3

    /// Whether a message refers to someone it doesn't name, so the one before says who.
    static func pointsBack(_ message: String) -> Bool {
        MemoryNormalize.words(message).contains { pronouns.contains($0) }
    }

    /// Whether a message carries meaning to search for. "Thanks!" and "Good morning" don't.
    static func hasContent(_ message: String) -> Bool { !asked(message).isEmpty }

    static func pick(_ message: String, facts: [MemoryFact], similarity: [UUID: Float] = [:],
                     closeEnough: Float? = nil, limit: Int = limit, budgetChars: Int = budgetChars) -> [MemoryFact] {
        let words = asked(message)
        guard !words.isEmpty else { return [] }
        let close = closeInMeaning(similarity, closeEnough: closeEnough)
        let scored: [(MemoryFact, Float)] = facts.compactMap { fact in
            let shared = Float(score(fact, words))
            let near = close.contains(fact.id)
            guard shared > 0 || near else { return nil }
            return (fact, shared + (near ? meaningWeight * (similarity[fact.id] ?? 0) : 0))
        }
        let ranked = scored.sorted { a, b in
            a.1 != b.1 ? a.1 > b.1 : MemoryStore.importance(a.0, b.0)
        }
        var kept: [MemoryFact] = []
        var used = 0
        for (fact, _) in ranked {
            if kept.count == limit { break }
            let cost = fact.text.count + 3
            if used + cost > budgetChars { continue }
            kept.append(fact)
            used += cost
        }
        return kept
    }

    /// Close enough in meaning, and standing out from the rest once there are enough to compare.
    private static func closeInMeaning(_ similarity: [UUID: Float], closeEnough: Float?) -> Set<UUID> {
        guard !similarity.isEmpty else { return [] }
        let threshold = closeEnough ?? 0.37
        let values = Array(similarity.values)
        let mean = values.reduce(0, +) / Float(values.count)
        let spread = (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)).squareRoot()
        return Set(similarity.filter { _, s in
            s >= threshold && (values.count < spreadFrom || (spread > 0 && (s - mean) / spread >= standsOut))
        }.keys)
    }

    /// A name counts most, then a relation or topic word, then any other shared word.
    private static func score(_ fact: MemoryFact, _ words: Set<String>) -> Int {
        let subject: Set<String> = fact.subject == MemoryFact.user ? [] : contentWords(fact.subject)
        let relation: Set<String> = fact.isNote ? [] : contentWords(fact.predicate.replacingOccurrences(of: "_", with: " "))
        let value = contentWords(fact.value)
        return 3 * words.intersection(subject).count + 2 * words.intersection(relation).count + words.intersection(value).count
    }

    /// How a fact reads to the embedder: in the user's voice, to match how they ask.
    static func documentText(_ fact: MemoryFact) -> String {
        if fact.isNote { return fact.value }
        let relation = fact.predicate.replacingOccurrences(of: "_", with: " ")
        return fact.subject == MemoryFact.user ? "My \(relation): \(fact.value)" : "\(fact.subject)'s \(relation): \(fact.value)"
    }

    private static func asked(_ message: String) -> Set<String> {
        contentWords(message.memoryReplacing(greeting, with: " "))
    }

    /// The words that carry meaning, stemmed; numbers under 100 don't count.
    static func contentWords(_ text: String) -> Set<String> {
        Set(MemoryNormalize.words(text)
            .filter { !stopWords.contains($0) && !($0.count < 3 && $0.allSatisfy(\.isNumber)) }
            .map(stem))
    }

    /// "sisters" and "sister's" match "sister".
    private static func stem(_ word: String) -> String {
        (word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss")) ? String(word.dropLast()) : word
    }

    private static let pronouns: Set<String> = ["he", "she", "him", "her", "his", "hers", "they", "them", "their", "theirs"]

    private static let greeting = #"\bgood (morning|afternoon|evening|night)\b|\bhow (are|r) (you|u)( doing| going)?( today| tonight| this (morning|afternoon|evening))?\b|\bhow'?s it going\b|\bwhat'?s up\b|\bnice to meet you\b"#

    private static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "so", "to", "for", "of", "in", "on", "at", "by", "with", "from", "about", "into",
        "is", "are", "was", "were", "be", "been", "am", "do", "does", "did", "done", "have", "has", "had", "will", "would", "can",
        "could", "should", "may", "might", "must", "shall", "i", "me", "my", "mine", "myself", "you", "your", "yours", "we", "our",
        "us", "he", "she", "him", "her", "his", "hers", "they", "them", "their", "it", "its", "this", "that", "these", "those",
        "what", "which", "who", "whom", "whose", "when", "where", "why", "how", "any", "some", "all", "no", "not", "yes", "please",
        "tell", "give", "get", "make", "let", "know", "want", "need", "like", "just", "also", "too", "very", "up", "out", "now",
        "then", "there", "here", "user", "anu", "hi", "hey", "ok", "okay", "thank", "thanks", "remember", "s", "t", "ll", "re", "ve", "d", "m",
    ]
}
