import SwiftUI

// MARK: - How a fact reads (pure, unit-tested)

/// How a fact reads in the Memory screen: the fact is the label, and a second
/// line says how it relates to the user (Android `FactWords`).
struct MemoryFactWords: Equatable {
    /// The value ("Maya Chen"), or a sentence when the relation is a verb ("Lives in Pune").
    var label: String
    /// "Your manager", "Maya's birthday". Nil when the label is already a sentence.
    var relationship: String?

    private static let verbs: Set<String> = ["likes", "dislikes", "lives", "works", "prefers", "loves", "enjoys", "hates",
                                             "plays", "speaks", "drinks", "eats", "reports", "studies", "owns", "drives", "uses", "buys"]
    private static let prepositions: Set<String> = ["in", "at", "to", "for", "with", "on", "from", "as"]

    init(label: String, relationship: String?) {
        self.label = label
        self.relationship = relationship
    }

    init(_ fact: MemoryFact) {
        self = Self.words(subject: fact.subject, predicate: fact.predicate, value: fact.value, isNote: fact.isNote)
        if fact.status == .upcoming, let day = fact.startsOn {
            let from = "from \(MemoryFact.dayText(day))"
            relationship = relationship.map { "\($0) · \(from)" } ?? Self.sentenceCase(from)
        }
    }

    static func words(subject: String, predicate: String, value: String, isNote: Bool = false) -> MemoryFactWords {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNote { return MemoryFactWords(label: sentenceCase(value), relationship: nil) }
        let relation = predicate.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        let parts = relation.lowercased().split(separator: " ").map(String.init)
        let isUser = subject == MemoryFact.user
        func sentence(_ text: String) -> String { isUser ? sentenceCase(text) : "\(subject) \(text)" }
        let answer = value.lowercased()
        if ["true", "yes"].contains(answer) {
            return MemoryFactWords(label: isUser ? sentenceCase(relation) : "\(subject) \(relation)", relationship: nil)
        }
        if ["false", "no"].contains(answer) {
            return MemoryFactWords(label: "\(isUser ? sentenceCase(relation) : "\(subject) · \(relation)"): \(value)", relationship: nil)
        }
        let verb = !parts.isEmpty && (verbs.contains(parts[0]) || (parts.count > 1 && prepositions.contains(parts.last!)))
        if verb && (parts.count == 1 || prepositions.contains(parts.last!)) {
            return MemoryFactWords(label: sentence("\(relation) \(value)"), relationship: nil)
        }
        if verb {
            return MemoryFactWords(label: sentenceCase(value), relationship: isUser ? sentenceCase(relation) : "\(subject) · \(relation)")
        }
        return MemoryFactWords(label: sentenceCase(value), relationship: isUser ? "Your \(relation)" : "\(subject)'s \(relation)")
    }

    static func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// Whether a fact matches what's typed in search: every word must appear in how it reads.
    static func matches(_ fact: MemoryFact, query: String) -> Bool {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return true }
        let reads = MemoryFactWords(fact)
        let haystack = [reads.label, reads.relationship ?? "", fact.subject, fact.predicate.replacingOccurrences(of: "_", with: " "),
                        fact.value, fact.section.shortName].joined(separator: " ").lowercased()
        return words.allSatisfy(haystack.contains)
    }

    static func sourceName(_ source: MemoryEventSource) -> String {
        switch source {
        case .chat: return "Your message"
        case .statement: return "You asked Anu to remember"
        case .edit: return "Your edit"
        case .migrated: return "Saved in an earlier version"
        }
    }
}

// MARK: - Memory Inspector

/// See, search, confirm, correct and delete everything Anu remembers, with
/// where each fact came from. Settings → Memory.
struct MemoryView: View {
    @ObservedObject private var store = MemoryStore.shared
    @ObservedObject private var learner = MemoryLearner.shared
    @State private var query = ""
    @State private var selected: MemoryFact?
    @State private var adding = false
    @State private var confirmForgetAll = false

    private var visible: [MemoryFact] {
        store.shown.filter { MemoryFactWords.matches($0, query: query) }
    }

    var body: some View {
        List {
            Section {
                learningRow
            } footer: {
                Text("Anu learns from what you tell it about yourself, on this device only, while your phone charges or after a chat. Memory never goes to the cloud.")
            }

            if store.shown.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Nothing yet").font(.anuHeading)
                        Text("Tell Anu about yourself in chat, say \"remember …\", or tap + to add something in your own words.")
                            .font(.anuSecondary).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Space.xs)
                }
            } else if visible.isEmpty {
                Section { Text("No facts match “\(query)”.").foregroundStyle(.secondary) }
            }

            ForEach(FactSection.allCases, id: \.self) { section in
                let inSection = visible.filter { $0.section == section }.sorted(by: MemoryStore.importance)
                if !inSection.isEmpty {
                    Section(section.shortName) {
                        ForEach(inSection) { fact in
                            MemoryFactRow(fact: fact) { store.confirm(id: fact.id) }
                                .contentShape(Rectangle())
                                .onTapGesture { selected = fact }
                                .swipeActions {
                                    Button("Delete", role: .destructive) { store.delete(id: fact.id) }
                                }
                        }
                    }
                }
            }

            if !store.shown.isEmpty {
                Section {
                    Button("Forget Everything", role: .destructive) { confirmForgetAll = true }
                        .accessibilityIdentifier("memoryForgetAll")
                }
            }
        }
        .searchable(text: $query, prompt: "Search memory")
        .navigationTitle("Memory")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add a memory")
                    .accessibilityIdentifier("memoryAdd")
            }
        }
        .sheet(item: $selected) { fact in
            MemoryFactSheet(factID: fact.id)
        }
        .sheet(isPresented: $adding) {
            MemoryAddSheet()
        }
        .confirmationDialog("Forget everything Anu remembers?", isPresented: $confirmForgetAll, titleVisibility: .visible) {
            Button("Forget Everything", role: .destructive) { store.deleteAll() }
        } message: {
            Text("Every fact and the messages they came from are deleted from this device. This can't be undone.")
        }
    }

    @ViewBuilder private var learningRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: Space.hair) {
                Text("\(store.shown.count) fact\(store.shown.count == 1 ? "" : "s")")
                Text(learningStatus).font(.anuMeta).foregroundStyle(.secondary)
            }
            Spacer()
            if learner.isLearning {
                ProgressView()
            } else {
                Button("Learn now") { Task { await learner.learnNow() } }
                    .disabled(store.pendingCount == 0)
                    .accessibilityIdentifier("memoryLearnNow")
            }
        }
    }

    private var learningStatus: String {
        if learner.isLearning { return "Learning on this device…" }
        if learner.lastRun?.noModel == true, store.pendingCount > 0 {
            return "\(store.pendingCount) waiting · download an on-device model in Settings → Model"
        }
        if store.pendingCount > 0 { return "\(store.pendingCount) message\(store.pendingCount == 1 ? "" : "s") waiting to learn from" }
        return "Up to date"
    }
}

/// One fact in the list: the label, how it relates, and its status on the right.
private struct MemoryFactRow: View {
    let fact: MemoryFact
    let confirm: () -> Void

    var body: some View {
        let words = MemoryFactWords(fact)
        HStack(alignment: .center, spacing: Space.base) {
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(words.label).foregroundStyle(.primary)
                let subtitle = [words.relationship, fact.sensitive ? "Private" : nil].compactMap { $0 }.joined(separator: " · ")
                if !subtitle.isEmpty {
                    Text(subtitle).font(.anuMeta).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Space.snug)
            switch fact.badge {
            case .needsConfirming:
                Button("Confirm", action: confirm)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityIdentifier("memoryConfirm")
            case .youSaid:
                Text("You said").font(.anuMeta).foregroundStyle(.secondary)
            case .confirmed:
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    .accessibilityLabel("Confirmed")
            case .upcoming:
                Image(systemName: "calendar").foregroundStyle(.secondary)
                    .accessibilityLabel("Upcoming")
            }
        }
    }
}

// MARK: - A fact's sheet

private struct MemoryFactSheet: View {
    let factID: UUID
    @ObservedObject private var store = MemoryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var correcting = false
    @State private var newValue = ""
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Group {
                if let fact = store.fact(id: factID), fact.status != .superseded {
                    content(fact)
                } else {
                    Text("This fact was removed.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Memory")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func content(_ fact: MemoryFact) -> some View {
        let words = MemoryFactWords(fact)
        return List {
            Section {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(words.label).font(.anuTitle)
                    if let relationship = words.relationship {
                        Text(relationship).font(.anuSecondary).foregroundStyle(.secondary)
                    }
                    Text(statusLine(fact)).font(.anuMeta).foregroundStyle(.secondary)
                }
                .padding(.vertical, Space.xs)
            }

            Section {
                if fact.badge == .needsConfirming || fact.badge == .youSaid {
                    Button { store.confirm(id: fact.id) } label: { Label("That's right", systemImage: "checkmark") }
                        .accessibilityIdentifier("memoryThatsRight")
                }
                Button { newValue = fact.value; correcting = true } label: { Label("Correct", systemImage: "pencil") }
                    .accessibilityIdentifier("memoryCorrect")
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    .accessibilityIdentifier("memoryDelete")
            }

            let sources = store.sources(of: fact)
            Section("Where it came from") {
                if sources.isEmpty {
                    Text("No messages kept for this fact.").foregroundStyle(.secondary)
                }
                ForEach(sources) { event in
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(sourceTitle(event)).font(.anuMeta).foregroundStyle(.secondary)
                        Text("“\(String(event.content.prefix(280)))”")
                        if event.source == .chat || event.source == .statement {
                            Button("Forget this message", role: .destructive) { store.forgetSource(event.id) }
                                .font(.anuLabel)
                                .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, Space.hair)
                }
            }

            if !fact.history.isEmpty {
                Section("History") {
                    ForEach(Array(fact.history.reversed().enumerated()), id: \.offset) { _, revision in
                        HStack(alignment: .firstTextBaseline) {
                            Text(revision.change)
                            Spacer()
                            Text(revision.at.formatted(date: .abbreviated, time: .omitted))
                                .font(.anuMeta).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .alert("Correct this fact", isPresented: $correcting) {
            TextField("Value", text: $newValue)
            Button("Save") { store.correct(id: fact.id, value: newValue) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anu will use your words, and won't learn the old value again.")
        }
        .confirmationDialog("Delete this fact?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.delete(id: fact.id); dismiss() }
        } message: {
            Text("Anu won't learn it again from chat.")
        }
    }

    private func statusLine(_ fact: MemoryFact) -> String {
        var parts: [String] = [fact.section.shortName]
        switch fact.badge {
        case .confirmed: parts.append("Confirmed by you")
        case .youSaid: parts.append("You said")
        case .needsConfirming: parts.append("Learned · \(Int((fact.confidence * 100).rounded()))% sure · needs confirming")
        case .upcoming(let day): parts.append("Upcoming, from \(MemoryFact.dayText(day))")
        }
        if fact.sensitive { parts.append("Private") }
        return parts.joined(separator: " · ")
    }

    private func sourceTitle(_ event: MemoryEvent) -> String {
        var title = "\(MemoryFactWords.sourceName(event.source)) · \(event.at.formatted(date: .long, time: .shortened))"
        if let place = event.place, !place.isEmpty { title += " · in “\(place)”" }
        return title
    }
}

// MARK: - Add

private struct MemoryAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var refused = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Something about you, in your own words", text: $text, axis: .vertical)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("newMemoryField")
                } footer: {
                    Text(refused
                         ? "Anu doesn't keep passwords, codes, or card, bank or ID numbers in memory."
                         : "Kept as something you said. The on-device model files it into the right section.")
                }
            }
            .navigationTitle("Add to Memory")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard MemoryStore.shared.add(text) != nil else { refused = true; return }
                        Task { await MemoryLearner.shared.learnNow() }
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("memorySave")
                }
            }
        }
    }
}
