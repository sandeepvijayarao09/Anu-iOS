import Foundation
import NaturalLanguage

// Live camera's "find by meaning" (Android's LiveSearch / Finder, adapted):
// a question such as "where's something to sit on?" is matched to the
// detector's labels, by Apple's on-device sentence embedding when present
// and by a deterministic concept table always (and alone in tests).
// The question stays in memory; nothing here touches the network or disk.

/// Text → vector. `NLEmbedding` in the app; fakes in tests.
protocol LiveTextEmbedding {
    func vector(for text: String) -> [Double]?
}

/// Apple's English sentence embedding, on device.
final class NLSentenceTextEmbedding: LiveTextEmbedding {
    private let embedding: NLEmbedding
    init?() {
        guard let e = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        embedding = e
    }
    func vector(for text: String) -> [Double]? { embedding.vector(for: text) }
}

final class LiveLabelMatcher {
    private let embedder: LiveTextEmbedding?
    private var labelVectors: [String: [Double]] = [:]
    /// Calibrated on NLEmbedding (2026-11-12): "something to sit on" → chair
    /// 0.52 / couch 0.51; "anything to drink" → bottle 0.58 / cup 0.51; "my
    /// keys" best 0.43, so it matches nothing.
    var minimumSimilarity = 0.5
    var margin = 0.05
    var maxSemanticMatches = 3

    init(embedder: LiveTextEmbedding? = NLSentenceTextEmbedding()) {
        self.embedder = embedder
    }

    /// True when meaning-matching is available (otherwise words only).
    var usesEmbedding: Bool { embedder != nil }

    // MARK: Deterministic concepts

    /// Intent words → the labels that answer them.
    static let concepts: [(words: [String], labels: [String])] = [
        (["sit", "seat", "sitting", "rest"], ["chair", "couch", "sofa", "bench", "bed"]),
        (["drink", "thirsty", "beverage", "water", "coffee", "tea"], ["cup", "bottle", "wine glass", "glass", "wine"]),
        (["eat", "food", "hungry", "snack", "meal"], ["food", "fruit", "banana", "apple", "sandwich", "orange",
                                                      "pizza", "donut", "cake", "bowl", "hot dog", "broccoli", "carrot"]),
        (["read", "sign", "words", "written", "writing", "say", "says", "label"], ["text", "book"]),
        (["animal", "pet", "pets"], ["cat", "dog", "bird", "horse", "sheep", "cow"]),
        (["someone", "somebody", "people", "anyone", "anybody", "human", "who", "man", "woman", "kid"], ["person", "face"]),
        (["computer", "type", "typing", "work"], ["laptop", "keyboard", "mouse", "computer", "screen"]),
        (["watch", "tv", "show"], ["tv", "television", "screen"]),
        (["sleep", "lie", "nap"], ["bed", "couch", "sofa"]),
        (["green", "leaf", "leaves"], ["potted plant", "plant", "flower", "tree"]),
        (["document", "paper", "card", "display", "monitor"], ["rectangle", "screen", "book"]),
        (["time"], ["clock"]),
        (["call", "phone", "mobile"], ["cell phone", "phone"]),
        (["ride", "drive", "vehicle"], ["car", "bicycle", "motorcycle", "bus", "truck"]),
    ]

    /// Short glosses so a label's vector carries its use, not just its word.
    static let glosses: [String: String] = [
        "chair": "a seat to sit on", "couch": "a sofa to sit or lie on", "sofa": "a couch to sit on",
        "bench": "a long seat", "bed": "a bed to sleep on", "cup": "a cup to drink from",
        "bottle": "a bottle of drink", "wine glass": "a glass to drink wine from", "glass": "a glass to drink from",
        "cat": "a pet cat, an animal", "dog": "a pet dog, an animal", "person": "a person",
        "face": "a person's face", "laptop": "a laptop computer", "keyboard": "a computer keyboard",
        "text": "written words, a sign", "book": "a book to read",
        "rectangle": "a flat rectangle like a screen, paper or sign", "clock": "a clock that tells the time",
        "tv": "a television screen", "potted plant": "a plant in a pot", "food": "food to eat",
    ]

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
            .map { $0.count > 3 && $0.hasSuffix("s") && !$0.hasSuffix("ss") ? String($0.dropLast()) : $0 }
    }

    /// Labels the deterministic table and direct words pick, in vocabulary order.
    func wordMatches(question: String, vocabulary: [String]) -> [String] {
        let qWords = Set(Self.words(question))
        guard !qWords.isEmpty else { return [] }
        var wanted = Set<String>()
        for label in vocabulary {
            let lw = Self.words(label)
            if !lw.isEmpty, lw.allSatisfy(qWords.contains) { wanted.insert(label) }
        }
        for concept in Self.concepts where concept.words.contains(where: qWords.contains) {
            wanted.formUnion(concept.labels)
        }
        return vocabulary.filter(wanted.contains)
    }

    /// Labels the sentence embedding picks: close to the question and near
    /// the best score, at most `maxSemanticMatches`.
    func semanticMatches(question: String, vocabulary: [String]) -> [String] {
        guard let embedder, let q = embedder.vector(for: question) else { return [] }
        let scored = vocabulary.compactMap { label -> (String, Double)? in
            guard let v = vectorForLabel(label, embedder) else { return nil }
            return (label, Self.cosine(q, v))
        }.sorted { $0.1 > $1.1 }
        guard let best = scored.first?.1, best >= minimumSimilarity else { return [] }
        return scored.prefix(maxSemanticMatches)
            .filter { $0.1 >= minimumSimilarity && $0.1 >= best - margin }
            .map(\.0)
    }

    /// The labels a question is looking for: words and concepts first, then meaning.
    func labels(for question: String, vocabulary: [String]) -> [String] {
        var result = wordMatches(question: question, vocabulary: vocabulary)
        for label in semanticMatches(question: question, vocabulary: vocabulary) where !result.contains(label) {
            result.append(label)
        }
        return result
    }

    /// Detections that answer the question: label matches, plus text whose
    /// recognized words appear in the question ("find the EXIT sign").
    func matches(question: String, in detections: [LiveDetection], vocabulary: [String]) -> [LiveDetection] {
        let vocab = vocabulary + detections.map(\.matchKey).filter { !vocabulary.contains($0) }
        let wanted = Set(labels(for: question, vocabulary: vocab))
        let qWords = Set(Self.words(question))
        return detections.filter { d in
            if wanted.contains(d.matchKey) { return true }
            if d.source == .text { return Self.words(d.label).contains { $0.count > 2 && qWords.contains($0) } }
            return false
        }
    }

    private func vectorForLabel(_ label: String, _ embedder: LiveTextEmbedding) -> [Double]? {
        if let v = labelVectors[label] { return v }
        let text = Self.glosses[label].map { "\(label): \($0)" } ?? label
        let v = embedder.vector(for: text)
        if let v { labelVectors[label] = v }
        return v
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}

// MARK: - Words on screen and for the model

enum LiveCameraText {
    /// Most certain first, boxes before scene labels, capped.
    static func ordered(_ detections: [LiveDetection], limit: Int = 8) -> [LiveDetection] {
        Array(detections.sorted {
            ($0.source == .scene ? 1 : 0, -$0.confidence) < ($1.source == .scene ? 1 : 0, -$1.confidence)
        }.prefix(limit))
    }

    /// The line under the search field.
    static func status(question: String, detections: [LiveDetection], matches: [LiveDetection],
                       wanted: [String], vocabularyCount: Int) -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            let names = unique(ordered(detections).map(\.matchKey))
            return names.isEmpty ? "Nothing recognised yet" : "\(names.count) in view: \(names.joined(separator: ", "))"
        }
        if !matches.isEmpty {
            let names = unique(ordered(matches).map(\.matchKey))
            return "Found \(names.joined(separator: ", "))"
        }
        if !wanted.isEmpty { return "Looking for \(list(Array(wanted.prefix(4)), conjunction: "or"))" }
        return "Anu can spot \(vocabularyCount) kinds of things here, and none of them fits that."
    }

    /// The chat message for "Ask Anu": the user's question plus what the
    /// on-device detector found, as context the model may overrule.
    static func prompt(question: String, detections: [LiveDetection], detectorName: String) -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let ask = q.isEmpty ? "What's in this picture?" : q
        let found = ordered(detections).map(\.caption)
        let note: String
        if found.isEmpty {
            note = "This is a frame from my live camera. The on-device detector (\(detectorName)) found nothing it knows in it, so go by the picture."
        } else {
            note = "This is a frame from my live camera. On this phone, \(detectorName) found: \(found.joined(separator: ", ")). It knows only a few kinds of things and can miss or misname them, so go by the picture."
        }
        return "\(ask)\n\n(\(note))"
    }

    static func list(_ items: [String], conjunction: String) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " \(conjunction) " + items.last!
        }
    }

    private static func unique(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { seen.insert($0).inserted }
    }
}
