import Foundation
import NaturalLanguage

// MARK: - Task types

enum TaskType: String, CaseIterable, Sendable {
    case casualChat = "casual_chat"
    case math
    case webInfo = "web_info"
    case codeGen = "code_gen"
    case longWriting = "long_writing"
    case generalQA = "general_qa"
}

struct TaskClassification: Sendable, Equatable {
    let type: TaskType
    let confidence: Double
}

// MARK: - Classifier

/// On-device ML task classifier.
///
/// Uses Apple's NLEmbedding sentence embeddings (bundled with iOS, runs in
/// milliseconds): each task type is represented by the centroid of a handful
/// of seed utterances; an incoming prompt is assigned to the nearest centroid
/// by cosine similarity. Falls back to keyword rules when embeddings are
/// unavailable (e.g. unsupported locale).
@MainActor
final class TaskClassifier {
    static let shared = TaskClassifier()

    private static let seeds: [TaskType: [String]] = [
        .casualChat: [
            "hi", "hello there", "how are you doing today",
            "good morning", "tell me something fun", "I had a rough day",
            "what's your favorite color", "thanks, you're awesome",
        ],
        .math: [
            "calculate 12 * 8 + 5", "what is 15% of 847",
            "compute the square root of 144", "how much is 23 plus 19",
            "convert 5 miles to kilometers", "what's 2 to the power of 10",
        ],
        .webInfo: [
            "search for the latest AI news", "what's the weather like today",
            "look up the current bitcoin price", "what happened in the news",
            "find the latest iPhone reviews", "who won the game last night",
        ],
        .codeGen: [
            "write a python function to sort a list",
            "debug this swift code", "write a regex for email validation",
            "how do I implement a linked list", "fix this compiler error",
            "write a script to rename files",
        ],
        .longWriting: [
            "write me an essay about space exploration",
            "draft an email to my landlord", "write a story about a dragon",
            "summarize this article", "write a cover letter for a job",
            "translate this paragraph to spanish",
        ],
        .generalQA: [
            "why is the sky blue", "what is the capital of France",
            "explain how photosynthesis works", "what does DNS mean",
            "who wrote Romeo and Juliet", "how do vaccines work",
        ],
    ]

    private let embedding: NLEmbedding?
    private var centroids: [TaskType: [Double]] = [:]

    private init() {
        embedding = NLEmbedding.sentenceEmbedding(for: .english)
        if let embedding {
            for (type, examples) in Self.seeds {
                let vectors = examples.compactMap { embedding.vector(for: $0.lowercased()) }
                guard !vectors.isEmpty else { continue }
                var centroid = [Double](repeating: 0, count: vectors[0].count)
                for v in vectors {
                    for i in v.indices { centroid[i] += v[i] }
                }
                centroids[type] = centroid.map { $0 / Double(vectors.count) }
            }
        }
    }

    func classify(_ text: String) -> TaskClassification {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return TaskClassification(type: .casualChat, confidence: 1) }

        if let embedding,
           !centroids.isEmpty,
           let vector = embedding.vector(for: trimmed.lowercased()) {
            // Hybrid: embedding similarity + a prior boost for the type an
            // explicit task verb points at ("draft …", "calculate …") —
            // topic words can otherwise drag a request toward the wrong
            // centroid (e.g. "essay on climate change" → web info).
            let keywordHint = Self.keywordFallback(trimmed)
            var best: (TaskType, Double) = (.generalQA, -1)
            for (type, centroid) in centroids {
                var score = Self.cosine(vector, centroid)
                if type == keywordHint.type, keywordHint.confidence >= 0.7 {
                    score += 0.12
                }
                if score > best.1 { best = (type, score) }
            }
            return TaskClassification(type: best.0, confidence: min(1, max(0, best.1)))
        }

        return Self.keywordFallback(trimmed)
    }

    // MARK: - Internals

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return -1 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? dot / denom : -1
    }

    /// Keyword fallback for when sentence embeddings are unavailable.
    static func keywordFallback(_ text: String) -> TaskClassification {
        let lower = text.lowercased()
        // Match keywords on word boundaries, not raw substrings: otherwise a
        // short token like "api" would fire inside "capital" and "code" inside
        // "barcode", misrouting ordinary questions to code-gen.
        func has(_ words: [String]) -> Bool {
            words.contains { kw in
                lower.range(of: "\\b" + NSRegularExpression.escapedPattern(for: kw) + "\\b",
                            options: .regularExpression) != nil
            }
        }

        if lower.range(of: #"\d\s*[\+\-\*\/\^×÷]\s*\d|\d\s*%"#, options: .regularExpression) != nil
            || has(["calculate", "compute", "convert", "how many", "how much"]) {
            return TaskClassification(type: .math, confidence: 0.7)
        }
        if has(["search", "look up", "latest", "news", "current", "weather", "price"]) {
            return TaskClassification(type: .webInfo, confidence: 0.7)
        }
        if has(["code", "function", "script", "debug", "regex", "compile", "compiler",
                "programming", "algorithm", "syntax", "exception",
                "json", "sql", "query", "api", "parse", "loop", "array", "async",
                "python", "javascript", "typescript"]) {
            return TaskClassification(type: .codeGen, confidence: 0.7)
        }
        if has(["write", "essay", "draft", "story", "summarize", "translate", "letter"]) {
            return TaskClassification(type: .longWriting, confidence: 0.7)
        }
        if has(["why", "what is", "explain", "how do", "who"]) {
            return TaskClassification(type: .generalQA, confidence: 0.6)
        }
        return TaskClassification(type: .casualChat, confidence: 0.6)
    }
}
