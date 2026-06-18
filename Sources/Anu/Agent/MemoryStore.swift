import Foundation
import NaturalLanguage

// MARK: - Memory note

/// One thing Anu remembers — fully visible and editable by the user
/// (Settings → Memory). NotebookLM-style: notes are the *sources* responses
/// get grounded in.
struct MemoryNote: Identifiable, Codable, Equatable {
    let id: UUID
    var content: String
    var createdAt: Date
    var updatedAt: Date
    /// Sentence embedding for retrieval (recomputed on edit).
    var embedding: [Double]?

    init(content: String) {
        self.id = UUID()
        self.content = content
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Store

/// Persistent, user-editable memory with embedding-based retrieval.
@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    @Published private(set) var notes: [MemoryNote] = []

    static let maxNotes = 100
    private let fileURL: URL
    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)

    init(directory: URL? = nil) {
        let dir = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("memory.json")
        load()
    }

    // MARK: CRUD

    @discardableResult
    func add(_ content: String) -> MemoryNote {
        var note = MemoryNote(content: content)
        note.embedding = embedding?.vector(for: content.lowercased())
        notes.insert(note, at: 0)
        if notes.count > Self.maxNotes { notes.removeLast() }
        save()
        return note
    }

    func update(id: UUID, content: String) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[idx].content = content
        notes[idx].updatedAt = Date()
        notes[idx].embedding = embedding?.vector(for: content.lowercased())
        save()
    }

    func delete(id: UUID) {
        notes.removeAll { $0.id == id }
        save()
    }

    func deleteAll() {
        notes = []
        save()
    }

    // MARK: Retrieval (the NotebookLM part)

    /// Top-k notes relevant to a query, by embedding cosine similarity
    /// (token-overlap fallback when embeddings are unavailable).
    func retrieve(for query: String, limit: Int = 3) -> [MemoryNote] {
        guard !notes.isEmpty else { return [] }

        if let embedding, let queryVector = embedding.vector(for: query.lowercased()) {
            return notes
                .compactMap { note -> (MemoryNote, Double)? in
                    guard let v = note.embedding else { return nil }
                    let sim = Self.cosine(queryVector, v)
                    return sim >= 0.30 ? (note, sim) : nil
                }
                .sorted { $0.1 > $1.1 }
                .prefix(limit)
                .map(\.0)
        }

        // Fallback: simple token overlap
        let queryTokens = Set(query.lowercased().split(separator: " ").map(String.init))
        return notes
            .compactMap { note -> (MemoryNote, Int)? in
                let noteTokens = Set(note.content.lowercased().split(separator: " ").map(String.init))
                let overlap = queryTokens.intersection(noteTokens).count
                return overlap > 0 ? (note, overlap) : nil
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// The personalization layer for a prompt: a standing profile of the
    /// most recent memories (ALWAYS included, whatever the topic) merged
    /// with query-relevant older notes. Every prompt gets this — memory is
    /// a layer, not an occasional lookup.
    func context(for query: String, alwaysOn: Int = 3, totalLimit: Int = 8) -> (notes: [MemoryNote], block: String?) {
        guard !notes.isEmpty else { return ([], nil) }

        // Tier 1: standing profile — newest notes, unconditionally
        let profile = Array(notes.prefix(alwaysOn))
        let profileIds = Set(profile.map(\.id))

        // Tier 2: query-relevant older notes (deduplicated)
        let relevant = retrieve(for: query, limit: totalLimit)
            .filter { !profileIds.contains($0.id) }

        let combined = Array((profile + relevant).prefix(totalLimit))
        return (combined, Self.groundingBlock(for: combined))
    }

    /// Builds the grounded-sources block injected into prompts, numbered so
    /// the model (and the trace) can cite them as [M1], [M2]…
    static func groundingBlock(for retrieved: [MemoryNote]) -> String? {
        guard !retrieved.isEmpty else { return nil }
        let numbered = retrieved.enumerated()
            .map { "[M\($0.offset + 1)] \($0.element.content)" }
            .joined(separator: "\n")
        return """
        Saved memory about the user (treat these as ground truth; when an \
        answer relies on one, you may cite it like [M1]):
        \(numbered)
        """
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode([MemoryNote].self, from: data) else { return }
        notes = loaded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]
        }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom > 0 ? dot / denom : -1
    }
}
