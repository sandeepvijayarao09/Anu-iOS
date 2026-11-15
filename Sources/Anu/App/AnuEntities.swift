import AppIntents
import CoreTransferable
import Foundation
import UniformTypeIdentifiers
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

// MARK: - What may be shown to Siri and Spotlight
//
// Android parity A5. Chats, memory facts and workflows are App Intents
// entities so Siri and Spotlight can find and open them. The rules for what
// may leave Anu's own screens live here, in one place, as pure functions:
//
// - an incognito ("ephemeral") chat is never indexed, suggested or exposed;
// - a chat with its own memory ("isolated") is never indexed either: the user
//   set it apart from everything else on purpose;
// - a memory fact marked private (`sensitive`: health, money, location, IDs,
//   intimate details) is never indexed, and neither is a superseded one;
// - nothing is indexed when the user turns off Settings → Search.
//
// What *is* indexed is the minimum that makes a result recognisable: a chat's
// title, a fact's text, a workflow's name. Message bodies, a fact's evidence
// and a workflow's prompt stay out of the system index. The index itself is
// Apple's on-device Spotlight index; it does not sync.

enum AnuIndexPolicy {
    /// UserDefaults switch behind Settings → Search. Absent means on.
    static let enabledKey = "spotlight_indexing_enabled"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// A chat may be indexed, suggested to Siri, or shown as on-screen content.
    static func isShareable(_ session: ChatSession) -> Bool {
        !session.ephemeral && session.memoryScope != .isolated
    }

    /// A memory fact may be indexed or suggested.
    static func isShareable(_ fact: MemoryFact) -> Bool {
        !fact.sensitive && fact.status != .superseded
    }

    static func chats(_ sessions: [ChatSession]) -> [ChatEntity] {
        sessions.filter(isShareable).map(ChatEntity.init)
    }

    static func facts(_ facts: [MemoryFact]) -> [MemoryFactEntity] {
        facts.filter(isShareable).map(MemoryFactEntity.init)
    }
}

// MARK: - Chat

/// One saved chat (a `ChatSession`). Siri can find it by name, open it, and,
/// while it's on screen, read it when you ask ("summarise this").
struct ChatEntity: AppEntity, Identifiable, Equatable {
    /// `NSUserActivity` type advertised while a chat is open.
    static let activityType = "io.github.sandeepvijayarao09.anu.chat"

    let id: UUID
    let name: String
    let updatedAt: Date

    init(id: UUID, name: String, updatedAt: Date) {
        self.id = id
        self.name = name
        self.updatedAt = updatedAt
    }

    init(_ session: ChatSession) {
        self.init(id: session.id, name: session.name, updatedAt: session.updatedAt)
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Anu Chat" }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "Anu chat")
    }

    static var defaultQuery = ChatEntityQuery()
}

/// Reads the session index from disk (through `SecureFile`) so it works when
/// Siri or Spotlight launch Anu in the background, before the UI loaded.
struct ChatEntityQuery: EntityStringQuery {
    /// Injectable for tests.
    var sessions: @Sendable () -> [ChatSession] = { SessionStore().loadIndex()?.sessions ?? [] }
    var defaults: @Sendable () -> UserDefaults = { .standard }

    init() {}
    init(sessions: @escaping @Sendable () -> [ChatSession], defaults: @escaping @Sendable () -> UserDefaults = { .standard }) {
        self.sessions = sessions
        self.defaults = defaults
    }

    /// Resolving a known ID still works with search turned off (a shortcut the
    /// user built keeps working), but never for an incognito or isolated chat.
    func entities(for identifiers: [ChatEntity.ID]) async throws -> [ChatEntity] {
        let wanted = Set(identifiers)
        return AnuIndexPolicy.chats(sessions()).filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [ChatEntity] {
        let term = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return try await suggestedEntities() }
        return try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(term) }
    }

    /// Newest first. Empty when the user turned search off.
    func suggestedEntities() async throws -> [ChatEntity] {
        guard AnuIndexPolicy.isEnabled(defaults()) else { return [] }
        return AnuIndexPolicy.chats(sessions()).sorted { $0.updatedAt > $1.updatedAt }
    }
}

extension ChatEntity {
    /// The conversation as plain text, for Siri when the user asks about the
    /// chat on screen. User and Anu turns only; tool traffic and system notes
    /// are left out. Nil for a chat that isn't shareable.
    static func transcript(for id: UUID, store: SessionStore = SessionStore()) -> String? {
        guard let session = store.loadIndex()?.sessions.first(where: { $0.id == id }),
              AnuIndexPolicy.isShareable(session),
              let snapshot = store.conversationStore(for: id).load() else { return nil }
        return transcript(name: session.name, messages: snapshot.messages)
    }

    static func transcript(name: String, messages: [AgentMessage]) -> String {
        let lines = messages.compactMap { message -> String? in
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            switch message.role {
            case .user: return "You: \(text)"
            case .assistant: return "Anu: \(text)"
            default: return nil
            }
        }
        return ([name] + lines).joined(separator: "\n\n")
    }
}

extension ChatEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { entity in
            Data((ChatEntity.transcript(for: entity.id) ?? entity.name).utf8)
        }
    }
}

// MARK: - Memory fact

/// One thing Anu remembers. Private facts never become entities.
struct MemoryFactEntity: AppEntity, Identifiable, Equatable {
    let id: UUID
    let text: String
    let section: String
    let updatedAt: Date

    init(id: UUID, text: String, section: String, updatedAt: Date) {
        self.id = id
        self.text = text
        self.section = section
        self.updatedAt = updatedAt
    }

    init(_ fact: MemoryFact) {
        self.init(id: fact.id, text: fact.text, section: fact.section.rawValue, updatedAt: fact.lastConfirmed)
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Anu Memory" }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(text)", subtitle: "Anu memory")
    }

    static var defaultQuery = MemoryFactEntityQuery()
}

struct MemoryFactEntityQuery: EntityStringQuery {
    init() {}

    @MainActor private func shown() -> [MemoryFact] { MemoryStore.shared.shown }

    func entities(for identifiers: [MemoryFactEntity.ID]) async throws -> [MemoryFactEntity] {
        let wanted = Set(identifiers)
        return AnuIndexPolicy.facts(await shown()).filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [MemoryFactEntity] {
        let term = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return try await suggestedEntities() }
        return try await suggestedEntities().filter { $0.text.localizedCaseInsensitiveContains(term) }
    }

    func suggestedEntities() async throws -> [MemoryFactEntity] {
        guard AnuIndexPolicy.isEnabled() else { return [] }
        return AnuIndexPolicy.facts(await shown())
    }
}

// MARK: - Spotlight attributes (IndexedEntity, iOS 18 / macOS 15)

#if canImport(CoreSpotlight)
@available(iOS 18.0, macOS 15.0, *)
extension ChatEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attrs = CSSearchableItemAttributeSet(contentType: .text)
        attrs.title = name
        attrs.displayName = name
        attrs.contentDescription = "Anu chat"
        attrs.contentModificationDate = updatedAt
        attrs.keywords = ["Anu", "chat"]
        return attrs
    }
}

@available(iOS 18.0, macOS 15.0, *)
extension MemoryFactEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attrs = CSSearchableItemAttributeSet(contentType: .text)
        attrs.title = text
        attrs.displayName = text
        attrs.contentDescription = "Anu memory"
        attrs.contentModificationDate = updatedAt
        attrs.keywords = ["Anu", "memory", section]
        return attrs
    }
}

/// Workflows keep their existing Spotlight items (`SpotlightIndexer`, tap to
/// run); on iOS 18+ those items are linked to this entity so Siri knows what
/// they are. Only the name is indexed — never the saved prompt.
@available(iOS 18.0, macOS 15.0, *)
extension WorkflowEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attrs = CSSearchableItemAttributeSet(contentType: .text)
        attrs.title = name
        attrs.displayName = name
        attrs.contentDescription = "Anu workflow"
        attrs.keywords = ["Anu", "workflow", "AI"]
        return attrs
    }
}

// The system asks the query to rebuild its part of the index (after a restore,
// or when the index is lost). iOS 27 / macOS 27.

#if compiler(>=6.4)  // iOS 27 SDK APIs (Xcode 27)
@available(iOS 27.0, macOS 27.0, *)
extension ChatEntityQuery: IndexedEntityQuery {
    func reindexEntities(for identifiers: [ChatEntity.ID], indexDescription: CSSearchableIndexDescription) async throws {
        await AnuSearchIndex.reindexFromSystem()
    }
    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await AnuSearchIndex.reindexFromSystem()
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension MemoryFactEntityQuery: IndexedEntityQuery {
    func reindexEntities(for identifiers: [MemoryFactEntity.ID], indexDescription: CSSearchableIndexDescription) async throws {
        await AnuSearchIndex.reindexFromSystem()
    }
    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await AnuSearchIndex.reindexFromSystem()
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension WorkflowEntityQuery: IndexedEntityQuery {
    func reindexEntities(for identifiers: [WorkflowEntity.ID], indexDescription: CSSearchableIndexDescription) async throws {
        await AnuSearchIndex.reindexFromSystem()
    }
    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await AnuSearchIndex.reindexFromSystem()
    }
}
#endif
#endif
