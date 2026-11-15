import Foundation

// The notes tools (Android `connector:notes`, ADR-093). They run only through
// `ToolBroker`: adding a note changes only the user's own data, so it is a
// private write (runs by itself unless the run is tainted, then asks with the
// exact title and text); searching and listing are reads. Notes are the
// user's own words, so reading them never taints a run (P4).

enum NotesTools {
    static let names = ["notes_add", "notes_search", "notes_list"]

    @MainActor
    static func register(in registry: ToolRegistry, store: NoteStore = .shared) {
        registry.register(NotesAddTool(store: store))
        registry.register(NotesSearchTool(store: store))
        registry.register(NotesListTool(store: store))
    }

    /// One note in a tool result: its title and the start of its text.
    static func render(_ notes: [Note], empty: String) -> String {
        guard !notes.isEmpty else { return empty }
        return notes.map { "• \($0.title): \(NoteStore.excerpt($0.text))" }.joined(separator: "\n")
    }
}

struct NotesAddTool: Tool {
    let store: NoteStore
    let name = "notes_add"
    let description = "Save a new note in Anu on this phone, such as a list or an idea. 'text' is the note; 'title' is optional."

    var parameters: JSONSchema? {
        .object(
            description: "The note",
            properties: [
                "text": .string(description: "The note's words, as the user gave them"),
                "title": .string(description: "A short title, e.g. Groceries. Leave it out to use the first words"),
            ],
            required: ["text"]
        )
    }

    func risk(for arguments: JSONValue) -> RiskTier { .writePrivate }

    func describe(_ arguments: JSONValue) -> String {
        let title = ToolDescribing.text(arguments, "title")
            ?? NoteStore.firstWords(ToolDescribing.text(arguments, "text") ?? "")
        return "Save a note in Anu, \(ToolDescribing.quoted(title))"
    }

    var editableFields: [EditableField] {
        [EditableField(key: "title", label: "Title", kind: .line, optional: true),
         EditableField(key: "text", label: "Note", kind: .text)]
    }

    func execute(arguments: JSONValue) async throws -> String {
        guard let text = ToolDescribing.text(arguments, "text") else { throw ToolError.missingArgument("text") }
        do {
            let note = try store.add(title: ToolDescribing.text(arguments, "title") ?? "", text: text)
            return "Saved the note \(ToolDescribing.quoted(note.title)) in Anu."
        } catch let error as NoteError {
            throw ToolError.executionFailed(error.errorDescription ?? "The note wasn't saved.")
        }
    }
}

struct NotesSearchTool: Tool {
    let store: NoteStore
    let name = "notes_search"
    let description = "Find the user's notes in Anu by words in their title or text."

    var parameters: JSONSchema? {
        .object(
            description: "What to look for",
            properties: ["query": .string(description: "Words to look for in the notes' titles and text")],
            required: ["query"]
        )
    }

    func describe(_ arguments: JSONValue) -> String {
        guard let query = ToolDescribing.text(arguments, "query") else { return "Look at your newest notes" }
        return "Look for \(ToolDescribing.quoted(query)) in your notes"
    }

    func execute(arguments: JSONValue) async throws -> String {
        let query = ToolDescribing.text(arguments, "query") ?? ""
        let found = store.search(query)
        let empty = store.all.isEmpty ? "There are no notes in Anu yet."
            : "No note has \(ToolDescribing.quoted(NoteStore.searchable(query)))."
        return NotesTools.render(found, empty: empty)
    }
}

struct NotesListTool: Tool {
    let store: NoteStore
    let name = "notes_list"
    let description = "List the user's newest notes in Anu, with their titles."

    var parameters: JSONSchema? {
        .object(
            description: "How many",
            properties: ["limit": .integer(description: "How many notes, newest first (1-10, default 5)")],
            required: []
        )
    }

    func describe(_ arguments: JSONValue) -> String { "Look at your newest notes" }

    func execute(arguments: JSONValue) async throws -> String {
        let limit = min(max(arguments["limit"]?.intValue ?? NoteStore.maxFound, 1), 10)
        let all = store.all
        let shown = NotesTools.render(Array(all.prefix(limit)), empty: "There are no notes in Anu yet.")
        return all.count > limit ? shown + "\n(\(all.count) notes in all.)" : shown
    }
}
