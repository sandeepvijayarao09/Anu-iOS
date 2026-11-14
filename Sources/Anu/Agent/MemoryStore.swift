import Foundation

// Memory v2 (Android parity #3–#5; Android ARCHITECTURE §8, ADR-054, ADR-147).
//
// A fact is a subject, a relation and a value, with where it came from (the
// dated messages behind it, I4), how sure Anu is, who said it (the user's own
// word outranks anything inferred, P5), its status (active, upcoming from a
// day, superseded) and an edit history. Everything is user-visible and
// editable in Settings → Memory, stays on this device, and is written only
// through `SecureFile` (encrypted, excluded from backup).

// MARK: - Model

/// The living profile's sections. The raw values are what the extractor writes.
/// `notes` holds free-text memories (from earlier builds, or "remember …"
/// before the on-device model has structured them).
enum FactSection: String, Codable, CaseIterable, Sendable {
    case identity, people, work, routines, preferences, goals, places, notes

    /// What the model reads.
    var title: String {
        switch self {
        case .identity: return "Identity and roles"
        case .people: return "People and relationships"
        case .work: return "Work and projects"
        case .routines: return "Routines and schedule"
        case .preferences: return "Preferences"
        case .goals: return "Goals and commitments"
        case .places: return "Places"
        case .notes: return "Notes"
        }
    }

    /// What people see.
    var shortName: String {
        switch self {
        case .identity: return "About you"
        case .people: return "People"
        case .work: return "Work"
        case .routines: return "Routines"
        case .preferences: return "Preferences"
        case .goals: return "Goals"
        case .places: return "Places"
        case .notes: return "Notes"
        }
    }
}

/// Who a fact came from. The user's own word outranks anything inferred (P5).
enum FactOrigin: String, Codable, Sendable {
    case userStated, inferred
}

/// `upcoming`: true from `startsOn`, not yet (ADR-147); it replaces nothing until then.
enum FactStatus: String, Codable, Sendable {
    case active, superseded, upcoming
}

/// Where a memory event came from.
enum MemoryEventSource: String, Codable, Sendable {
    /// A message the user wrote in chat.
    case chat
    /// The user told Anu directly ("remember …", or Memory → Add).
    case statement
    /// The user confirmed or corrected a fact in the Memory screen.
    case edit
    /// A memory note saved by an earlier build.
    case migrated
}

enum MemoryEventStatus: String, Codable, Sendable {
    case pending, done, failed
}

/// An append-only record of something the user said. Facts point back to these (I4).
struct MemoryEvent: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var at: Date
    var source: MemoryEventSource
    /// What was said. Messages about passwords or codes are never kept, and
    /// card, bank and ID numbers are cut (I1).
    var content: String
    /// Where it came from, e.g. "chat:<session>/<message>".
    var ref: String?
    /// The chat's name when it was said, for "In Trip planning".
    var place: String?
    var status: MemoryEventStatus
    var attempts: Int

    init(id: UUID = UUID(), at: Date, source: MemoryEventSource, content: String,
         ref: String? = nil, place: String? = nil, status: MemoryEventStatus, attempts: Int = 0) {
        self.id = id; self.at = at; self.source = source; self.content = content
        self.ref = ref; self.place = place; self.status = status; self.attempts = attempts
    }
}

/// One entry in a fact's edit history.
struct FactRevision: Codable, Equatable, Sendable {
    var at: Date
    var change: String
}

/// One thing Anu knows. Every fact has at least one source event (I4).
struct MemoryFact: Identifiable, Codable, Equatable, Sendable {
    /// The subject Anu uses for the user themself.
    static let user = "user"
    /// The relation of a free-text memory.
    static let notePredicate = "note"

    let id: UUID
    var subject: String
    var predicate: String
    var value: String
    var section: FactSection
    var confidence: Double
    var origin: FactOrigin
    var status: FactStatus
    /// Health, money, precise location, IDs or intimate details. Memory never leaves the phone.
    var sensitive: Bool
    /// The user's words that state it ("because you said …").
    var evidence: String?
    var firstSeen: Date
    var lastConfirmed: Date
    var supersededBy: UUID?
    var sources: [UUID]
    /// The day an upcoming fact comes true (ADR-147), and kept once it has.
    var startsOn: Date?
    /// The user tapped "That's right" or corrected it.
    var confirmedByUser: Bool
    var history: [FactRevision]
    /// Search-by-meaning vector (Float32, little-endian) and the embedder that made it.
    var vector: Data?
    var vectorModel: String?

    init(id: UUID = UUID(), subject: String, predicate: String, value: String, section: FactSection,
         confidence: Double, origin: FactOrigin, status: FactStatus = .active, sensitive: Bool = false,
         evidence: String? = nil, firstSeen: Date, lastConfirmed: Date? = nil, supersededBy: UUID? = nil,
         sources: [UUID], startsOn: Date? = nil, confirmedByUser: Bool = false, history: [FactRevision] = []) {
        self.id = id; self.subject = subject; self.predicate = predicate; self.value = value
        self.section = section; self.confidence = confidence; self.origin = origin; self.status = status
        self.sensitive = sensitive; self.evidence = evidence; self.firstSeen = firstSeen
        self.lastConfirmed = lastConfirmed ?? firstSeen; self.supersededBy = supersededBy
        self.sources = sources; self.startsOn = startsOn; self.confirmedByUser = confirmedByUser
        self.history = history
    }

    /// A free-text memory in the user's own words (earlier builds' `MemoryNote`).
    init(content: String) {
        let now = Date()
        self.init(subject: Self.user, predicate: Self.notePredicate, value: content, section: .notes,
                  confidence: 1, origin: .userStated, firstSeen: now, sources: [],
                  history: [FactRevision(at: now, change: "You said it")])
    }

    var isNote: Bool { predicate == Self.notePredicate }

    /// How the fact reads to the model: "manager: Maya Chen", "Maya Chen · birthday: 12 March".
    var text: String {
        let base: String
        if isNote {
            base = value
        } else {
            let relation = predicate.replacingOccurrences(of: "_", with: " ")
            base = subject == Self.user ? "\(relation): \(value)" : "\(subject) · \(relation): \(value)"
        }
        if status == .upcoming, let startsOn { return base + " (from \(Self.dayText(startsOn)))" }
        return base
    }

    // Compatibility with earlier builds' `MemoryNote` API.
    var content: String { text }
    var createdAt: Date { firstSeen }
    var updatedAt: Date { lastConfirmed }

    /// What the Memory screen shows next to a fact.
    enum Badge: Equatable {
        case confirmed, youSaid, needsConfirming, upcoming(Date)
    }

    var badge: Badge {
        if status == .upcoming, let startsOn { return .upcoming(startsOn) }
        if confirmedByUser { return .confirmed }
        return origin == .userStated ? .youSaid : .needsConfirming
    }

    static func dayText(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "d MMMM yyyy"
        return f.string(from: date)
    }
}

/// Earlier builds' name for a memory; the store migrates them to facts.
typealias MemoryNote = MemoryFact

/// The outcome of one learning run.
struct LearnResult: Equatable, Sendable {
    var processed = 0
    var learned = 0
    var failed = 0
    /// No on-device model could run, so nothing could be learned yet.
    var noModel = false
    /// Another run was already going.
    var busy = false
}

// MARK: - Store

/// Persistent, user-editable memory: facts with provenance, reconciliation,
/// dated facts and retrieval by words and meaning.
@MainActor
final class MemoryStore: ObservableObject {
    static let shared: MemoryStore = {
        let store = MemoryStore()
        // Test isolation: launch with "-reset_memory YES" to start with no facts.
        if UserDefaults.standard.bool(forKey: "reset_memory") { store.deleteAll() }
        return store
    }()

    /// Every fact, including superseded ones (kept as history), newest first.
    @Published private(set) var facts: [MemoryFact] = []
    /// The messages facts came from, and messages waiting to be learned from.
    @Published private(set) var events: [MemoryEvent] = []

    static let maxFacts = 300
    static let maxNotes = maxFacts
    static let maxEvents = 1_000
    /// Learning attempts before a message is dropped (P6).
    static let maxAttempts = 3
    /// The memory block's size in the prompt, in tokens (about 4 characters each).
    static let tokenBudget = 400

    private static let inferredConfidence = 0.6
    private static let confirmationStep = 0.15
    private static let confirmedCeiling = 0.95

    private let fileURL: URL
    private let keys: DataKeyProviding
    private var rejected: Set<String> = []
    private let clock: () -> Date
    let calendar: Calendar
    /// Search by meaning. Nil means words only (deterministic).
    let embedder: MemoryEmbedder?

    init(directory: URL? = nil,
         keys: DataKeyProviding = KeychainDataKey.shared,
         embedder: MemoryEmbedder? = MemoryEmbedders.onDevice(),
         calendar: Calendar = .current,
         clock: @escaping () -> Date = Date.init) {
        let dir = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        fileURL = dir.appendingPathComponent("memory.json")
        self.keys = keys
        self.embedder = embedder
        self.calendar = calendar
        self.clock = clock
        load()
        activateDue()
    }

    // MARK: Views of the facts

    /// What the Memory screen shows and the model may use: active and upcoming facts.
    var shown: [MemoryFact] { facts.filter { $0.status != .superseded } }
    /// Compatibility: earlier builds listed "notes".
    var notes: [MemoryFact] { shown }
    var pendingCount: Int { events.filter { $0.status == .pending }.count }

    func fact(id: UUID) -> MemoryFact? { facts.first { $0.id == id } }

    /// The dated messages a fact came from, newest first.
    func sources(of fact: MemoryFact) -> [MemoryEvent] {
        let ids = Set(fact.sources)
        return events.filter { ids.contains($0.id) }.sorted { $0.at > $1.at }
    }

    /// The user's own facts first, then the surest, then the most recently confirmed.
    nonisolated static func importance(_ a: MemoryFact, _ b: MemoryFact) -> Bool {
        if (a.origin == .userStated) != (b.origin == .userStated) { return a.origin == .userStated }
        if a.confidence != b.confidence { return a.confidence > b.confidence }
        return a.lastConfirmed > b.lastConfirmed
    }

    private var today: Date { calendar.startOfDay(for: clock()) }

    // MARK: 1. Capture

    /// Keeps a chat message to learn from later, if it is safe to keep and
    /// about the user or someone in their life. Returns the event, or nil.
    @discardableResult
    func captureChat(_ text: String, ref: String? = nil, place: String? = nil) -> MemoryEvent? {
        guard let content = MemoryFilters.forChat(text) else { return nil }
        let event = MemoryEvent(at: clock(), source: .chat, content: content, ref: ref, place: place, status: .pending)
        events.append(event)
        pruneEvents()
        save()
        return event
    }

    /// Something the user told Anu directly ("remember …", Memory → Add). It is
    /// kept at once in their own words, and the on-device model later files it
    /// as structured facts (kept as theirs, P5). Nil when it holds a secret.
    @discardableResult
    func add(_ content: String, ref: String? = nil) -> MemoryFact? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let cleaned = MemoryFilters.cleaned(trimmed) else { return nil }
        let now = clock()
        let event = MemoryEvent(at: now, source: .statement, content: cleaned, ref: ref, status: .pending)
        events.append(event)
        let fingerprint = MemoryNormalize.fingerprint(subject: MemoryFact.user, predicate: MemoryFact.notePredicate, value: cleaned)
        rejected.remove(fingerprint)
        var note = MemoryFact(subject: MemoryFact.user, predicate: MemoryFact.notePredicate, value: cleaned, section: .notes,
                              confidence: 1, origin: .userStated, evidence: cleaned, firstSeen: now, sources: [event.id],
                              history: [FactRevision(at: now, change: "You said it")])
        note.vector = vector(for: note)
        note.vectorModel = note.vector == nil ? nil : embedder?.id
        facts.insert(note, at: 0)
        enforceCap()
        pruneEvents()
        save()
        return note
    }

    /// A fact the user asked Anu to remember, through the `memory_remember`
    /// tool (Android `MemoryPipeline.remember`): kept at once as theirs (P5),
    /// reconciled like a learned fact, so a one-at-a-time relation replaces its
    /// old value. Nil when it holds a secret (I1) or a part is empty.
    @discardableResult
    func remember(about: String, what: String, value: String, section: FactSection,
                  sensitive: Bool = false, ref: String? = nil) -> MemoryFact? {
        let subject = MemoryNormalize.subject(about)
        let predicate = MemoryNormalize.predicate(what)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty, !predicate.isEmpty, !value.isEmpty,
              MemoryFilters.safeToKeep("\(subject) \(predicate) \(value)") else { return nil }
        let said = subject == MemoryFact.user
            ? "\(predicate.replacingOccurrences(of: "_", with: " ")): \(value)"
            : "\(subject) · \(predicate.replacingOccurrences(of: "_", with: " ")): \(value)"
        let event = MemoryEvent(at: clock(), source: .statement, content: said, ref: ref, status: .done, attempts: 1)
        events.append(event)
        let candidate = ExtractedFact(subject: subject, predicate: predicate, value: value, section: section,
                                      quote: "", sensitive: sensitive)
        _ = reconcile([candidate], event: event, origin: .userStated)
        enforceCap()
        pruneEvents()
        save()
        return facts.first {
            $0.status != .superseded && $0.sources.contains(event.id)
        }
    }

    // MARK: 2–3. Learn and reconcile

    /// Messages waiting to be learned from, oldest first.
    func pendingEvents(limit: Int = .max) -> [MemoryEvent] {
        Array(events.filter { $0.status == .pending }.sorted { $0.at < $1.at }.prefix(limit))
    }

    /// Records a failed extraction: the message waits for a later run, and is
    /// dropped after `maxAttempts` (P6).
    func markFailed(_ eventID: UUID) {
        guard let i = events.firstIndex(where: { $0.id == eventID }) else { return }
        events[i].attempts += 1
        events[i].status = events[i].attempts >= Self.maxAttempts ? .failed : .pending
        pruneEvents()
        save()
    }

    /// Step 3: reconciles what the extractor found in `eventID` with what is
    /// known. Returns how many facts were added or confirmed.
    @discardableResult
    func learn(_ candidates: [ExtractedFact], from eventID: UUID) -> Int {
        guard let i = events.firstIndex(where: { $0.id == eventID }) else { return 0 }
        events[i].attempts += 1
        events[i].status = .done
        let event = events[i]
        // What the user said directly stays theirs (P5).
        let origin: FactOrigin = (event.source == .chat) ? .inferred : .userStated
        let changed = reconcile(candidates, event: event, origin: origin)
        // A statement kept in the user's words is replaced by the structured
        // facts the model found in it.
        if event.source == .statement, changed > 0 {
            facts.removeAll { $0.isNote && $0.sources == [event.id] }
        }
        enforceCap()
        pruneEvents()
        save()
        return changed
    }

    private func reconcile(_ candidates: [ExtractedFact], event: MemoryEvent, origin: FactOrigin) -> Int {
        var changed = 0
        let now = clock()
        for candidate in candidates {
            let subject = MemoryNormalize.subject(candidate.subject)
            let predicate = MemoryNormalize.predicate(candidate.predicate)
            let value = candidate.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subject.isEmpty, !predicate.isEmpty, !value.isEmpty else { continue }
            let fingerprint = MemoryNormalize.fingerprint(subject: subject, predicate: predicate, value: value)
            if rejected.contains(fingerprint) {
                // A deleted or corrected fact is never learned again from chat,
                // but the user's own word brings it back (P5, ADR-057).
                guard origin == .userStated else { continue }
                rejected.remove(fingerprint)
            }
            let single = candidate.single || MemoryNormalize.singleValued.contains(predicate)
            let quote = candidate.quote.isEmpty ? nil : candidate.quote

            // A fact that comes true later is upcoming and replaces nothing until its day (ADR-147).
            if let startsOn = UpcomingDay.start(starts: candidate.starts, quote: candidate.quote, today: now,
                                                message: event.content, calendar: calendar) {
                let planned = indices { $0.status == .upcoming && self.same(subject, predicate, $0) }
                if let j = planned.first(where: { MemoryNormalize.value(facts[$0].value) == MemoryNormalize.value(value) }) {
                    facts[j].origin = stronger(origin, facts[j].origin)
                    facts[j].startsOn = startsOn
                    facts[j].lastConfirmed = now
                    facts[j].sources = unique(facts[j].sources + [event.id])
                    facts[j].sensitive = facts[j].sensitive || candidate.sensitive
                    facts[j].history.append(FactRevision(at: now, change: "Mentioned again, from \(MemoryFact.dayText(startsOn, calendar: calendar))"))
                } else {
                    let fact = newFact(subject, predicate, value, candidate, origin: origin, status: .upcoming,
                                       startsOn: startsOn, evidence: quote, event: event, now: now)
                    if single {
                        for j in planned {
                            facts[j].status = .superseded
                            facts[j].supersededBy = fact.id
                            facts[j].history.append(FactRevision(at: now, change: "Plan replaced by \(value)"))
                        }
                    }
                    facts.insert(fact, at: 0)
                }
                changed += 1
                continue
            }

            let related = indices { $0.status == .active && self.same(subject, predicate, $0) }
            if let j = related.first(where: { MemoryNormalize.value(facts[$0].value) == MemoryNormalize.value(value) }) {
                let wasConfidence = facts[j].confidence
                facts[j].origin = stronger(origin, facts[j].origin)
                facts[j].confidence = origin == .userStated
                    ? 1
                    : max(wasConfidence, min(Self.confirmedCeiling, wasConfidence + Self.confirmationStep))
                facts[j].sensitive = facts[j].sensitive || candidate.sensitive
                facts[j].evidence = facts[j].evidence ?? quote
                facts[j].lastConfirmed = now
                facts[j].sources = unique(facts[j].sources + [event.id])
                facts[j].history.append(FactRevision(at: now, change: origin == .userStated ? "You said it again" : "Mentioned again"))
                changed += 1
                continue
            }
            let replaced = single ? related : []
            // The user's own word stands until they change it themself (P5).
            if origin == .inferred, replaced.contains(where: { facts[$0].origin == .userStated }) { continue }
            let fact = newFact(subject, predicate, value, candidate, origin: origin, status: .active,
                               startsOn: nil, evidence: quote, event: event, now: now)
            for j in replaced {
                facts[j].status = .superseded
                facts[j].supersededBy = fact.id
                facts[j].history.append(FactRevision(at: now, change: "Replaced by \(value)"))
            }
            facts.insert(fact, at: 0)
            changed += 1
        }
        return changed
    }

    private func newFact(_ subject: String, _ predicate: String, _ value: String, _ candidate: ExtractedFact,
                         origin: FactOrigin, status: FactStatus, startsOn: Date?, evidence: String?,
                         event: MemoryEvent, now: Date) -> MemoryFact {
        var fact = MemoryFact(subject: subject, predicate: predicate, value: value, section: candidate.section,
                              confidence: origin == .userStated ? 1 : Self.inferredConfidence, origin: origin,
                              status: status, sensitive: candidate.sensitive, evidence: evidence, firstSeen: now,
                              sources: [event.id], startsOn: startsOn,
                              history: [FactRevision(at: now, change: origin == .userStated ? "You said it" : "Learned from your message")])
        fact.vector = vector(for: fact)
        fact.vectorModel = fact.vector == nil ? nil : embedder?.id
        return fact
    }

    /// Upcoming facts whose day has come become active and replace what they
    /// were to replace, by the usual rules: an inferred plan never replaces the
    /// user's own word (P5).
    func activateDue() {
        let today = self.today
        let due = indices { $0.status == .upcoming && ($0.startsOn ?? .distantPast) <= today }
        guard !due.isEmpty else { return }
        let now = clock()
        for i in due {
            let fact = facts[i]
            let related = indices { $0.status == .active && $0.id != fact.id && self.same(fact.subject, fact.predicate, $0) }
            let sameValue = related.first { MemoryNormalize.value(facts[$0].value) == MemoryNormalize.value(fact.value) }
            let single = MemoryNormalize.singleValued.contains(MemoryNormalize.predicate(fact.predicate))
            let replaced = single ? related.filter { $0 != sameValue } : []
            if let j = sameValue {
                facts[j].sources = unique(facts[j].sources + fact.sources)
                facts[j].lastConfirmed = now
                facts[i].status = .superseded
                facts[i].supersededBy = facts[j].id
            } else if fact.origin == .inferred, let blocker = replaced.first(where: { facts[$0].origin == .userStated }) {
                facts[i].status = .superseded
                facts[i].supersededBy = facts[blocker].id
                facts[i].history.append(FactRevision(at: now, change: "Its day came, but you'd said otherwise"))
            } else {
                facts[i].status = .active
                facts[i].lastConfirmed = now
                facts[i].history.append(FactRevision(at: now, change: "Became true"))
                for j in replaced {
                    facts[j].status = .superseded
                    facts[j].supersededBy = fact.id
                    facts[j].history.append(FactRevision(at: now, change: "Replaced by \(fact.value)"))
                }
            }
        }
        save()
    }

    // MARK: User control (Memory Inspector)

    /// "That's right": the fact becomes the user's own (P5).
    func confirm(id: UUID) {
        guard let i = facts.firstIndex(where: { $0.id == id }) else { return }
        let now = clock()
        let event = MemoryEvent(at: now, source: .edit, content: "You confirmed: \(facts[i].text)", status: .done, attempts: 1)
        events.append(event)
        facts[i].origin = .userStated
        facts[i].confidence = 1
        facts[i].confirmedByUser = true
        facts[i].lastConfirmed = now
        facts[i].sources = unique(facts[i].sources + [event.id])
        facts[i].history.append(FactRevision(at: now, change: "You confirmed it"))
        save()
    }

    /// The user's own value replaces the fact (P5). The wrong value is never learned again.
    func correct(id: UUID, value: String) {
        let newValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newValue.isEmpty, MemoryFilters.safeToKeep(newValue),
              let i = facts.firstIndex(where: { $0.id == id }) else { return }
        let old = facts[i]
        guard newValue != old.value else { confirm(id: id); return }
        let now = clock()
        rejected.insert(MemoryNormalize.fingerprint(subject: old.subject, predicate: old.predicate, value: old.value))
        rejected.remove(MemoryNormalize.fingerprint(subject: old.subject, predicate: old.predicate, value: newValue))
        facts[i].value = newValue
        let event = MemoryEvent(at: now, source: .edit, content: "You corrected: \(facts[i].text)", status: .done, attempts: 1)
        events.append(event)
        facts[i].origin = .userStated
        facts[i].confidence = 1
        facts[i].confirmedByUser = true
        facts[i].evidence = event.content
        facts[i].lastConfirmed = now
        facts[i].sources = [event.id]
        facts[i].history.append(FactRevision(at: now, change: "You corrected it from “\(old.value)”"))
        facts[i].vector = vector(for: facts[i])
        facts[i].vectorModel = facts[i].vector == nil ? nil : embedder?.id
        pruneEvents()
        save()
    }

    /// Compatibility: editing a memory's text corrects it.
    func update(id: UUID, content: String) { correct(id: id, value: content) }

    /// Deletes the fact; only its fingerprint stays, so it isn't learned again from chat.
    func delete(id: UUID) {
        guard let fact = facts.first(where: { $0.id == id }) else { return }
        rejected.insert(MemoryNormalize.fingerprint(subject: fact.subject, predicate: fact.predicate, value: fact.value))
        facts.removeAll { $0.id == id }
        pruneEvents()
        save()
    }

    /// Forgets a message and everything learned only from it; what those facts
    /// had replaced stands again (I5).
    func forgetSource(_ eventID: UUID) {
        let today = self.today
        events.removeAll { $0.id == eventID }
        for fact in facts where fact.sources.contains(eventID) {
            guard let i = facts.firstIndex(where: { $0.id == fact.id }) else { continue }
            let remaining = fact.sources.filter { $0 != eventID }
            if !remaining.isEmpty {
                facts[i].sources = remaining
                facts[i].evidence = nil
                continue
            }
            facts.remove(at: i)
            for j in indices({ $0.supersededBy == fact.id }) {
                facts[j].supersededBy = nil
                facts[j].status = (facts[j].startsOn.map { $0 > today } ?? false) ? .upcoming : .active
                facts[j].history.append(FactRevision(at: clock(), change: "Restored after you forgot a message"))
            }
        }
        save()
    }

    /// Forget everything: facts, messages and fingerprints.
    func deleteAll() {
        facts = []
        events = []
        rejected = []
        save()
    }

    // MARK: Retrieval (ADR-054, ADR-055)

    /// The facts that bear on `message`, most relevant first, by shared words
    /// and, when an embedder is available, by meaning. The message is read on
    /// its own unless it points back to someone ("and her birthday?").
    func relevant(for message: String, previous: String? = nil, limit: Int = MemoryRelevance.limit) -> [MemoryFact] {
        activateDue()
        let said = (previous != nil && MemoryRelevance.pointsBack(message)) ? "\(previous!)\n\(message)" : message
        let candidates = shown
        return MemoryRelevance.pick(said, facts: candidates, similarity: similarities(said, candidates),
                                    closeEnough: embedder?.closeEnough, limit: limit)
    }

    /// Compatibility with earlier builds.
    func retrieve(for query: String, limit: Int = 3) -> [MemoryFact] {
        relevant(for: query, limit: limit)
    }

    /// The memory block for a prompt: the facts relevant to this message, then
    /// the most important others, numbered [M1]… within `tokenBudget`. On-device
    /// prompts only; cloud turns never receive it.
    func context(for query: String, previous: String? = nil, tokenBudget: Int = MemoryStore.tokenBudget) -> (notes: [MemoryFact], block: String?) {
        let relevant = relevant(for: query, previous: previous)
        let ids = Set(relevant.map(\.id))
        let profile = shown.filter { !ids.contains($0.id) }.sorted(by: Self.importance)
        let budget = tokenBudget * 4 - Self.header.count
        var kept: [MemoryFact] = []
        var used = 0
        for fact in relevant + profile {
            let cost = Self.line(for: fact, number: kept.count + 1).count + 1
            if used + cost > budget { continue }
            kept.append(fact)
            used += cost
        }
        return (kept, Self.groundingBlock(for: kept))
    }

    static let header = "What you know about the user, from their own words and their edits in the Memory screen. When it disagrees with older messages in this chat, trust it, unless the user has just said otherwise. Facts marked private never go into anything that leaves this device. Use what fits naturally; don't write the [M1] labels in your answer."

    /// An answer without the [M1] labels the prompt numbers facts with: the
    /// model sometimes repeats them, and About this answer lists the facts used.
    static func strippingLabels(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s?\[M\d+(?:\s*,\s*M?\d+)*\]"#, with: "", options: .regularExpression)
    }

    /// The numbered block injected into prompts.
    static func groundingBlock(for facts: [MemoryFact]) -> String? {
        guard !facts.isEmpty else { return nil }
        let lines = facts.enumerated().map { line(for: $0.element, number: $0.offset + 1) }
        return "Saved memory about the user. \(header)\n" + lines.joined(separator: "\n")
    }

    private static func line(for fact: MemoryFact, number: Int) -> String {
        var notes: [String] = []
        if fact.origin == .inferred { notes.append("learned, not yet confirmed") }
        if fact.sensitive { notes.append("private") }
        return "[M\(number)] \(fact.text)" + (notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))")
    }

    // MARK: Search by meaning

    private func vector(for fact: MemoryFact) -> Data? {
        guard let embedder, let v = embedder.embed(MemoryRelevance.documentText(fact)) else { return nil }
        return MemoryVectors.pack(v)
    }

    private func similarities(_ message: String, _ candidates: [MemoryFact]) -> [UUID: Float] {
        guard let embedder, MemoryRelevance.hasContent(message) else { return [:] }
        let indexed = candidates.filter { $0.vectorModel == embedder.id && $0.vector != nil }
        guard !indexed.isEmpty, let query = embedder.embed(message) else { return [:] }
        var out: [UUID: Float] = [:]
        for fact in indexed {
            if let v = fact.vector.map(MemoryVectors.unpack) { out[fact.id] = MemoryVectors.cosine(query, v) }
        }
        return out
    }

    /// Gives every shown fact a vector for the current embedder, off the main
    /// actor. Facts learned before the embedder was available catch up here.
    /// Returns how many were embedded.
    @discardableResult
    func indexVectors() async -> Int {
        guard let embedder else { return 0 }
        let missing = shown.filter { $0.vectorModel != embedder.id || $0.vector == nil }
        guard !missing.isEmpty else { return 0 }
        let inputs = missing.map { ($0.id, MemoryRelevance.documentText($0)) }
        let vectors = await Task.detached(priority: .utility) {
            inputs.compactMap { id, text in embedder.embed(text).map { (id, MemoryVectors.pack($0)) } }
        }.value
        for (id, data) in vectors {
            guard let i = facts.firstIndex(where: { $0.id == id }) else { continue }
            facts[i].vector = data
            facts[i].vectorModel = embedder.id
        }
        if !vectors.isEmpty { save() }
        return vectors.count
    }

    // MARK: Helpers

    private func same(_ subject: String, _ predicate: String, _ fact: MemoryFact) -> Bool {
        fact.subject.caseInsensitiveCompare(subject) == .orderedSame
            && MemoryNormalize.predicate(fact.predicate) == MemoryNormalize.predicate(predicate)
    }

    private func indices(_ matching: (MemoryFact) -> Bool) -> [Int] {
        facts.indices.filter { matching(facts[$0]) }
    }

    private func stronger(_ a: FactOrigin, _ b: FactOrigin) -> FactOrigin {
        (a == .userStated || b == .userStated) ? .userStated : .inferred
    }

    private func unique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Keeps at most `maxFacts` shown facts: history goes first, then the oldest.
    private func enforceCap() {
        while facts.count > Self.maxFacts {
            if let i = facts.lastIndex(where: { $0.status == .superseded }) {
                facts.remove(at: i)
            } else {
                facts.removeLast()
            }
        }
    }

    /// Drops messages no fact needs once they've been read (a message that
    /// taught nothing isn't kept), and a statement whose note was deleted
    /// before it was learned from. Pending chat messages stay.
    private func pruneEvents() {
        let needed = Set(facts.flatMap(\.sources))
        events.removeAll { event in
            guard !needed.contains(event.id) else { return false }
            return event.status != .pending || event.source == .statement
        }
        if events.count > Self.maxEvents {
            let removable = events.enumerated()
                .filter { !needed.contains($0.element.id) }
                .sorted { $0.element.at < $1.element.at }
                .prefix(events.count - Self.maxEvents)
                .map(\.element.id)
            let drop = Set(removable)
            events.removeAll { drop.contains($0.id) }
        }
    }

    // MARK: Persistence

    private struct FileV2: Codable {
        var version = 2
        var facts: [MemoryFact]
        var events: [MemoryEvent]
        var rejected: [String]
    }

    /// Earlier builds stored `[MemoryNote]` with these fields.
    private struct LegacyNote: Codable {
        let id: UUID
        var content: String
        var createdAt: Date
        var updatedAt: Date
    }

    private func load() {
        guard let data = SecureFile.read(fileURL, keys: keys) else { return }
        if let file = try? JSONDecoder().decode(FileV2.self, from: data) {
            facts = file.facts
            events = file.events
            rejected = Set(file.rejected)
            return
        }
        guard let legacy = try? JSONDecoder().decode([LegacyNote].self, from: data) else { return }
        // Migrate: each note becomes a fact in the user's own words, with a
        // dated source saying where it came from.
        for note in legacy {
            let event = MemoryEvent(at: note.createdAt, source: .migrated, content: note.content, status: .done, attempts: 0)
            events.append(event)
            var history = [FactRevision(at: note.createdAt, change: "You saved it")]
            if note.updatedAt > note.createdAt { history.append(FactRevision(at: note.updatedAt, change: "You edited it")) }
            facts.append(MemoryFact(id: note.id, subject: MemoryFact.user, predicate: MemoryFact.notePredicate,
                                    value: note.content, section: .notes, confidence: 1, origin: .userStated,
                                    evidence: note.content, firstSeen: note.createdAt, lastConfirmed: note.updatedAt,
                                    sources: [event.id], history: history))
        }
        save()
    }

    private func save() {
        let file = FileV2(facts: facts, events: events, rejected: rejected.sorted())
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? SecureFile.write(data, to: fileURL, keys: keys)
    }
}
