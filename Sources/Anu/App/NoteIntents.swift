import AppIntents
import Foundation
import UniformTypeIdentifiers

// Anu's notes in Apple Intelligence's Notes domain (iOS 27 AppSchema): Siri
// and Shortcuts can create a note in Anu, add to one, or change one, and find
// Anu's notes by name, the same way they work with notes apps. The notes stay
// where they are, encrypted on this iPhone (NoteStore); nothing is sent.
// Anu keeps one account with one folder of plain-text notes, so folders, pins
// and attachments are accepted as the schema requires and shown as that one
// folder, unpinned, with no attachments.

#if compiler(>=6.4)  // iOS 27 SDK APIs (Xcode 27)
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .notes.note)
struct AnuNoteEntity: AppEntity {
    static let defaultQuery = AnuNoteQuery()

    let id: UUID
    var name: String
    var content: String?
    var folder: AnuNoteFolderEntity?
    var isPinned: Bool
    var attachments: [IntentFile]
    var creationDate: Date?
    var modificationDate: Date?

    init(_ note: Note) {
        id = note.id
        name = note.title
        content = note.text
        folder = .anu
        isPinned = false
        attachments = []
        creationDate = note.created
        modificationDate = note.updated
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(String((content ?? "").prefix(80)))")
    }
}

/// Anu's single notes account.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .notes.account)
struct AnuNoteAccountEntity: AppEntity {
    static let defaultQuery = AnuNoteAccountQuery()
    static let anu = AnuNoteAccountEntity(id: "anu", name: "On this iPhone")

    let id: String
    var name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

/// Anu's single notes folder.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .notes.folder)
struct AnuNoteFolderEntity: AppEntity {
    static let defaultQuery = AnuNoteFolderQuery()
    static let anu = AnuNoteFolderEntity(id: "anu", name: "Anu")

    let id: String
    var name: String
    var account: AnuNoteAccountEntity?
    var parentFolder: AnuNoteFolderEntity?

    init(id: String, name: String) {
        self.id = id
        self.name = name
        self.account = .anu
        self.parentFolder = nil
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

@available(iOS 27.0, macOS 27.0, *)
struct AnuNoteAccountQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AnuNoteAccountEntity] {
        identifiers.contains(AnuNoteAccountEntity.anu.id) ? [.anu] : []
    }
    func entities(matching string: String) async throws -> [AnuNoteAccountEntity] { [.anu] }
    func suggestedEntities() async throws -> [AnuNoteAccountEntity] { [.anu] }
}

@available(iOS 27.0, macOS 27.0, *)
struct AnuNoteFolderQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AnuNoteFolderEntity] {
        identifiers.contains(AnuNoteFolderEntity.anu.id) ? [.anu] : []
    }
    func entities(matching string: String) async throws -> [AnuNoteFolderEntity] { [.anu] }
    func suggestedEntities() async throws -> [AnuNoteFolderEntity] { [.anu] }
}

@available(iOS 27.0, macOS 27.0, *)
struct AnuNoteQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [AnuNoteEntity] {
        identifiers.compactMap { NoteStore.shared.note(id: $0) }.map(AnuNoteEntity.init)
    }

    func entities(matching string: String) async throws -> [AnuNoteEntity] {
        NoteStore.shared.search(string, limit: 20).map(AnuNoteEntity.init)
    }

    func suggestedEntities() async throws -> [AnuNoteEntity] {
        Array(NoteStore.shared.all.sorted { $0.updated > $1.updated }.prefix(20)).map(AnuNoteEntity.init)
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .notes.createNote)
struct CreateAnuNoteIntent: AppIntent {
    @Parameter var name: String
    @Parameter var content: String?
    @Parameter var folder: AnuNoteFolderEntity?
    @Parameter var isPinned: Bool
    @Parameter(supportedContentTypes: [.data]) var attachments: [IntentFile]

    func perform() async throws -> some ReturnsValue<AnuNoteEntity> {
        let note = try NoteStore.shared.add(title: name, text: content ?? name)
        return .result(value: AnuNoteEntity(note))
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .notes.appendText)
struct AppendToAnuNoteIntent: AppIntent {
    @Parameter var target: AnuNoteEntity
    @Parameter var content: String

    func perform() async throws -> some ReturnsValue<AnuNoteEntity> {
        guard let note = NoteStore.shared.note(id: target.id) else { throw NoteError.notFound }
        let updated = try NoteStore.shared.update(id: note.id, title: note.title, text: note.text + "\n" + content)
        return .result(value: AnuNoteEntity(updated))
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .notes.updateNote)
struct UpdateAnuNoteIntent: AppIntent {
    @Parameter var target: AnuNoteEntity
    @Parameter var name: String?
    @Parameter var content: String?
    @Parameter var folder: AnuNoteFolderEntity?
    @Parameter var isPinned: Bool?
    @Parameter(supportedContentTypes: [.data]) var attachments: [IntentFile]?

    func perform() async throws -> some ReturnsValue<AnuNoteEntity> {
        guard let note = NoteStore.shared.note(id: target.id) else { throw NoteError.notFound }
        let updated = try NoteStore.shared.update(id: note.id, title: name ?? note.title, text: content ?? note.text)
        return .result(value: AnuNoteEntity(updated))
    }
}
#endif
