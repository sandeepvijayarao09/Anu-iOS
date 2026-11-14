import Foundation

// Anu's own notes (Android parity: `connector:notes`, ADR-093). Neither iOS nor
// Android lets an app write the system's notes (Apple Notes has no API), so
// notes are kept in Anu, encrypted on the phone through `SecureFile`, and can
// be sent to Apple Notes or anywhere else with the share sheet. They never
// leave the phone otherwise.

extension Notification.Name {
    /// Posted on the main queue after the notes change, so the Notes page reloads.
    static let anuNotesChanged = Notification.Name("com.anu.notesChanged")
}

/// A note the user keeps in Anu.
struct Note: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var text: String
    let created: Date
    var updated: Date
}

/// Where notes are kept. Not `@MainActor`: tools reach it from the broker,
/// and a main-actor store in a tool path deadlocks XCTest (see
/// `CalendarAccess`). A lock guards the in-memory copy.
final class NoteStore: @unchecked Sendable {
    static let shared = NoteStore()

    static let maxText = 10_000
    static let maxTitle = 100
    static let maxNotes = 1_000
    /// Notes a search or list returns, newest first.
    static let maxFound = 5
    /// A long note's start in a tool result, so it fits the on-device context.
    static let maxExcerpt = 400
    private static let titleFromText = 40

    private let fileURL: URL
    private let keys: DataKeyProviding
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var notes: [Note] = []

    init(directory: URL? = nil,
         keys: DataKeyProviding = KeychainDataKey.shared,
         clock: @escaping @Sendable () -> Date = Date.init) {
        let dir = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = dir.appendingPathComponent("notes.json")
        self.keys = keys
        self.clock = clock
        if let data = SecureFile.read(fileURL, keys: keys),
           let saved = try? JSONDecoder().decode([Note].self, from: data) {
            notes = saved
        }
    }

    // MARK: Reading

    /// Every note, newest change first.
    var all: [Note] {
        lock.withLock { notes.sorted { $0.updated > $1.updated } }
    }

    func note(id: UUID) -> Note? { lock.withLock { notes.first { $0.id == id } } }

    /// Notes whose title or text holds every word of `query`, newest first;
    /// the newest of all for an empty query.
    func search(_ query: String, limit: Int = NoteStore.maxFound) -> [Note] {
        let words = Self.searchable(query).lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let matching = all.filter { note in
            let haystack = (note.title + "\n" + note.text).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        return Array(matching.prefix(limit))
    }

    // MARK: Writing

    /// Saves a new note. An empty title takes the text's first words.
    @discardableResult
    func add(title: String = "", text: String) throws -> Note {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw NoteError.empty }
        guard body.count <= Self.maxText else { throw NoteError.tooLong }
        let named = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard named.count <= Self.maxTitle else { throw NoteError.titleTooLong }
        let now = clock()
        let note = Note(id: UUID(), title: named.isEmpty ? Self.firstWords(body) : named,
                        text: body, created: now, updated: now)
        try mutate { notes in
            guard notes.count < Self.maxNotes else { throw NoteError.full }
            notes.append(note)
        }
        return note
    }

    /// Replaces a note's title and text (the Notes page's edit).
    @discardableResult
    func update(id: UUID, title: String, text: String) throws -> Note {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw NoteError.empty }
        guard body.count <= Self.maxText else { throw NoteError.tooLong }
        let named = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard named.count <= Self.maxTitle else { throw NoteError.titleTooLong }
        var result: Note?
        try mutate { notes in
            guard let index = notes.firstIndex(where: { $0.id == id }) else { throw NoteError.notFound }
            notes[index].title = named.isEmpty ? Self.firstWords(body) : named
            notes[index].text = body
            notes[index].updated = clock()
            result = notes[index]
        }
        return result!
    }

    func delete(id: UUID) {
        try? mutate { notes in notes.removeAll { $0.id == id } }
    }

    func deleteAll() {
        try? mutate { notes in notes.removeAll() }
    }

    private func mutate(_ change: (inout [Note]) throws -> Void) throws {
        let snapshot: [Note] = try lock.withLock {
            var copy = notes
            try change(&copy)
            notes = copy
            return copy
        }
        if let data = try? JSONEncoder().encode(snapshot) {
            try SecureFile.write(data, to: fileURL, keys: keys)
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .anuNotesChanged, object: nil) }
    }

    // MARK: Text helpers (Android's, ADR-131)

    /// Words that name a note rather than say what's in it: "my groceries
    /// note" looks for "groceries".
    private static let filler: Set<String> = ["my", "the", "a", "an", "note", "notes", "called", "named",
                                              "titled", "list", "on", "in", "of", "all", "any"]

    /// `query` without filler words, or as it is when nothing else is left.
    static func searchable(_ query: String) -> String {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let kept = words.filter { !filler.contains($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\"'?.,!"))) }
        return (kept.isEmpty ? words : kept).joined(separator: " ")
    }

    /// The first line's first words, as a title.
    static func firstWords(_ text: String) -> String {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard line.count > titleFromText else { return line }
        let cut = String(line.prefix(titleFromText))
        let end = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? cut
        return end.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A long note's start, for tool results.
    static func excerpt(_ text: String) -> String {
        text.count <= maxExcerpt ? text : String(text.prefix(maxExcerpt)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// What the share sheet sends: the title, then the text.
    static func shareText(_ note: Note) -> String {
        note.text.hasPrefix(note.title) ? note.text : note.title + "\n\n" + note.text
    }
}

enum NoteError: LocalizedError, Equatable {
    case empty, tooLong, titleTooLong, notFound, full

    var errorDescription: String? {
        switch self {
        case .empty: return "A note needs some words."
        case .tooLong: return "A note can be at most \(NoteStore.maxText) characters."
        case .titleTooLong: return "A note's title can be at most \(NoteStore.maxTitle) characters."
        case .notFound: return "That note isn't there any more."
        case .full: return "Anu keeps at most \(NoteStore.maxNotes) notes. Delete some first."
        }
    }
}
