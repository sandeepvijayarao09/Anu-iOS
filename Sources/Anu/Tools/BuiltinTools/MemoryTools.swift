import Foundation
import os

// The model's memory tools (Android parity #3; Android `core/memory/MemoryTools.kt`,
// ARCHITECTURE §8 "Tools", ADR-087, ADR-088, ADR-130):
// - `memory_search` (read): what Anu remembers, each fact with its id.
// - `memory_remember` (private write): runs by itself unless the turn is
//   tainted, when the broker asks first (P4).
// - `memory_forget` (destructive, as on Android): always asks, and the sheet
//   lists the exact facts; only those are deleted, even if memory changes in
//   between (I2).
// The tools never decide whether they run; ToolBroker does. They touch only the
// on-device MemoryStore (SecureFile), and nothing here leaves the phone.

/// What this chat may do with memory, from its session.
enum MemoryAccess: Equatable, Sendable {
    /// An ordinary chat: read, remember and forget.
    case full
    /// An incognito chat: memory can be read and facts forgotten, but nothing
    /// said here is kept.
    case noWrites
    /// A private sandbox: global memory is neither read nor written.
    case off

    init(session: ChatSession?) {
        guard let session else { self = .full; return }
        if session.memoryScope == .isolated { self = .off } else if session.ephemeral { self = .noWrites } else { self = .full }
    }

    /// Whether the turn is offered `tool`.
    func offers(_ toolName: String) -> Bool {
        guard MemoryTools.names.contains(toolName) else { return true }
        switch self {
        case .full: return true
        case .noWrites: return toolName != MemoryTools.remember
        case .off: return false
        }
    }
}

/// Where the memory tools find the store and the chat's access. Main-actor
/// closures, so the tools themselves stay plain `Sendable` values.
struct MemoryToolContext: Sendable {
    let store: @MainActor @Sendable () -> MemoryStore
    let access: @MainActor @Sendable () -> MemoryAccess

    static let shared = MemoryToolContext(store: { MemoryStore.shared }, access: { .full })
}

enum MemoryTools {
    static let remember = "memory_remember"
    static let search = "memory_search"
    static let forget = "memory_forget"
    static let names: Set<String> = [remember, search, forget]

    static let offInSandbox = "Memory is off in this private chat, so nothing was looked up, kept or forgotten. Tell the user so."
    static let offIncognito = "This chat is incognito, so nothing from it is kept in memory. Tell the user so."
    static let refusesSecrets = "Anu doesn't keep passwords, codes, or card, bank or ID numbers in memory. Tell the user so."

    static func makeAll(_ context: MemoryToolContext) -> [any Tool] {
        [RememberTool(context: context), SearchMemoryTool(context: context), ForgetMemoryTool(context: context)]
    }

    /// A fact in words, as the Memory screen reads it: "Your manager: Maya Chen", "Lives in Pune".
    static func sentence(subject: String, predicate: String, value: String) -> String {
        let words = MemoryFactWords.words(subject: subject, predicate: predicate, value: value,
                                          isNote: predicate == MemoryFact.notePredicate)
        guard let relationship = words.relationship else { return words.label }
        return "\(relationship): \(words.label)"
    }

    static func sentence(_ fact: MemoryFact) -> String {
        sentence(subject: fact.subject, predicate: fact.predicate, value: fact.value)
    }

    /// Runs `work` on the main actor when already there (the broker calls
    /// `describe` there); off it, returns nil rather than block.
    static func onMain<T>(_ work: @MainActor () -> T) -> T? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated { work() }
    }
}

// MARK: - memory_remember

struct RememberTool: Tool {
    let context: MemoryToolContext
    let name = MemoryTools.remember
    let description = "Save a lasting fact the user asked you to remember. It stays on this phone, in Settings → Memory."

    var parameters: JSONSchema? {
        .object(
            description: "The fact to keep",
            properties: [
                "about": .string(description: "\"user\" when it is about the user, otherwise the person's or thing's name"),
                "what": .string(description: "A short snake_case relation, such as manager, diet, birthday or prefers_meeting_time"),
                "value": .string(description: "Just the value, in a few words, such as \"Maya Chen\", \"vegetarian\" or \"mornings\""),
                "section": .string(description: "Where it belongs",
                                   enumValues: FactSection.allCases.map(\.rawValue)),
                "sensitive": .boolean(description: "True for health, money, precise location, ID numbers or intimate details"),
            ],
            required: ["what", "value", "section"]
        )
    }

    func risk(for arguments: JSONValue) -> RiskTier { .writePrivate }

    func describe(_ arguments: JSONValue) -> String {
        let parts = Self.parts(arguments)
        return "Remember " + ToolDescribing.quoted(MemoryTools.sentence(
            subject: MemoryNormalize.subject(parts.about), predicate: MemoryNormalize.predicate(parts.what), value: parts.value))
    }

    func execute(arguments: JSONValue) async throws -> String {
        let parts = Self.parts(arguments)
        guard !parts.what.isEmpty, parts.what.count <= 40 else { throw ToolError.invalidArgument("what", expected: "a short relation") }
        guard !parts.value.isEmpty, parts.value.count <= 120 else { throw ToolError.invalidArgument("value", expected: "1-120 characters") }
        guard parts.about.count <= 60 else { throw ToolError.invalidArgument("about", expected: "up to 60 characters") }
        let section = FactSection(rawValue: arguments["section"]?.stringValue ?? "") ?? .notes
        let sensitive = arguments["sensitive"]?.boolValue ?? false
        let context = self.context
        let outcome: String = await MainActor.run {
            switch context.access() {
            case .off: return "off:" + MemoryTools.offInSandbox
            case .noWrites: return "off:" + MemoryTools.offIncognito
            case .full: break
            }
            guard let fact = context.store().remember(about: parts.about, what: parts.what, value: parts.value,
                                                     section: section, sensitive: sensitive) else {
                return "off:" + MemoryTools.refusesSecrets
            }
            return "Remembered: \(MemoryTools.sentence(fact)). It's in Settings → Memory, where the user can see, correct or delete it."
        }
        if outcome.hasPrefix("off:") { throw ToolError.executionFailed(String(outcome.dropFirst(4))) }
        return outcome
    }

    static func parts(_ arguments: JSONValue) -> (about: String, what: String, value: String) {
        (ToolDescribing.text(arguments, "about") ?? MemoryFact.user,
         ToolDescribing.text(arguments, "what") ?? "",
         ToolDescribing.text(arguments, "value") ?? "")
    }
}

// MARK: - memory_search

struct SearchMemoryTool: Tool {
    let context: MemoryToolContext
    let name = MemoryTools.search
    let description = "Look up what you remember about the user or someone in their life. Each fact has an id for memory_forget."
    static let limit = 8

    var parameters: JSONSchema? {
        .object(
            description: "What to look for",
            properties: [
                "query": .string(description: "Words to look for, such as a name or a topic. Leave empty for the most important facts."),
            ],
            required: []
        )
    }

    func describe(_ arguments: JSONValue) -> String {
        guard let query = ToolDescribing.text(arguments, "query") else { return "Look up what you remember" }
        return "Look up what you remember about " + ToolDescribing.quoted(query)
    }

    func execute(arguments: JSONValue) async throws -> String {
        let query = ToolDescribing.text(arguments, "query") ?? ""
        guard query.count <= 200 else { throw ToolError.invalidArgument("query", expected: "up to 200 characters") }
        let context = self.context
        let result: String? = await MainActor.run {
            guard context.access() != .off else { return nil }
            let facts = Self.find(query, in: context.store())
            guard !facts.isEmpty else {
                return query.isEmpty ? "Memory is empty." : "Nothing in memory matches \(ToolDescribing.quoted(query))."
            }
            return facts.map { fact in
                let source = fact.origin == .userStated ? "the user said so" : "learned from chat"
                return "- id \(fact.id.uuidString): \(MemoryTools.sentence(fact)) (\(fact.section.shortName); \(source))"
            }.joined(separator: "\n")
        }
        guard let result else { throw ToolError.executionFailed(MemoryTools.offInSandbox) }
        return result
    }

    /// Facts whose words all appear in how they read, then the relevant ones,
    /// then (for an empty query) the most important.
    @MainActor
    static func find(_ query: String, in store: MemoryStore, limit: Int = limit) -> [MemoryFact] {
        let shown = store.shown
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Array(shown.sorted(by: MemoryStore.importance).prefix(limit))
        }
        var out = shown.filter { MemoryFactWords.matches($0, query: query) }.sorted(by: MemoryStore.importance)
        for fact in store.relevant(for: query, limit: limit) where !out.contains(where: { $0.id == fact.id }) {
            out.append(fact)
        }
        return Array(out.prefix(limit))
    }
}

// MARK: - memory_forget

struct ForgetMemoryTool: Tool {
    let context: MemoryToolContext
    let name = MemoryTools.forget
    let description = "Delete facts the user wants forgotten, by id from memory_search, or by matching text. The user approves the exact list."
    static let maxFacts = 20

    /// What each call resolved to when the user was asked, so exactly that is deleted.
    private let approved = OSAllocatedUnfairLock<[String: [UUID]]>(initialState: [:])

    init(context: MemoryToolContext) { self.context = context }

    var parameters: JSONSchema? {
        .object(
            description: "Which facts to forget",
            properties: [
                "ids": .array(items: .string(), description: "Fact ids from memory_search"),
                "query": .string(description: "Or words that match the facts to forget"),
            ],
            required: []
        )
    }

    /// Deleting can't be undone, so it always asks. A call that matches
    /// nothing deletes nothing, so it runs as a read and says so.
    func risk(for arguments: JSONValue) -> RiskTier {
        let context = self.context
        let none = MemoryTools.onMain { Self.resolve(arguments, in: context.store()).isEmpty } ?? false
        return none ? .read : .destructive
    }

    func approvalNote(for arguments: JSONValue) -> String? { "Forgotten facts can't be brought back" }

    func describe(_ arguments: JSONValue) -> String {
        let context = self.context
        guard let facts = MemoryTools.onMain({ Self.resolve(arguments, in: context.store()) }) else {
            return "Forget facts in memory"
        }
        approved.withLock { $0[arguments.canonicalJSON] = facts.map(\.id) }
        guard !facts.isEmpty else { return "Forget nothing: no fact in memory matches" }
        return "Forget " + facts.map { ToolDescribing.quoted(MemoryTools.sentence($0)) }.joined(separator: "; ")
    }

    func execute(arguments: JSONValue) async throws -> String {
        let ids = Self.ids(arguments)
        let query = ToolDescribing.text(arguments, "query") ?? ""
        guard !ids.isEmpty || !query.isEmpty else {
            throw ToolError.missingArgument("ids or query")
        }
        guard ids.count <= Self.maxFacts else { throw ToolError.invalidArgument("ids", expected: "at most 20 facts") }
        let key = arguments.canonicalJSON
        let snapshot = approved.withLock { $0.removeValue(forKey: key) }
        let context = self.context
        let result: String? = await MainActor.run {
            guard context.access() != .off else { return nil }
            let store = context.store()
            let targets = snapshot.map { $0.compactMap(store.fact(id:)) } ?? Self.resolve(arguments, in: store)
            guard !targets.isEmpty else {
                return "Nothing in memory matches that, so nothing was forgotten. Call memory_search to find the facts and their ids."
            }
            targets.forEach { store.delete(id: $0.id) }
            return "Forgot: " + targets.map { MemoryTools.sentence($0) }.joined(separator: "; ") + "."
        }
        guard let result else { throw ToolError.executionFailed(MemoryTools.offInSandbox) }
        return result
    }

    static func ids(_ arguments: JSONValue) -> [UUID] {
        (arguments["ids"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) } }
    }

    /// By id when ids are given, else every fact whose words hold all the query's words.
    @MainActor
    static func resolve(_ arguments: JSONValue, in store: MemoryStore) -> [MemoryFact] {
        let ids = Set(ids(arguments))
        if !ids.isEmpty { return store.shown.filter { ids.contains($0.id) } }
        guard let query = ToolDescribing.text(arguments, "query") else { return [] }
        return Array(store.shown.filter { MemoryFactWords.matches($0, query: query) }.prefix(maxFacts))
    }
}
