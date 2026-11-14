import SwiftUI

/// Gemini-style chat list: every conversation is an isolated "privacy sandbox".
/// Create, switch, rename, delete, and toggle ephemeral / memory-isolation.
struct SessionListView: View {
    // Use the shared orchestrator directly (matches the app's presented-view
    // pattern) so the sheet doesn't depend on environment-object propagation.
    @ObservedObject private var orchestrator = AgentOrchestrator.shared
    @Environment(\.dismiss) private var dismiss
    @State private var renameTarget: ChatSession?
    @State private var renameText = ""
    /// Backs `.searchable`. Also the landing point for `SearchAnuIntent`:
    /// adopting the `.system.search` assistant schema promises Siri that
    /// "search … in Anu" leads somewhere, so the app has to actually have a
    /// search field for the term to land in.
    @State private var searchText = ""

    /// Sessions filtered by name. Empty query shows everything.
    private var visibleSessions: [ChatSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return orchestrator.sessions }
        return orchestrator.sessions.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(visibleSessions) { session in
                    Button {
                        Task {
                            await orchestrator.switchSession(to: session.id)
                            dismiss()
                        }
                    } label: {
                        row(session)
                    }
                    .accessibilityIdentifier("sessionRow")
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await orchestrator.deleteSession(id: session.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .accessibilityIdentifier("deleteSessionButton")
                    }
                    .contextMenu {
                        Button {
                            startRename(session)
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button {
                            orchestrator.setEphemeral(!session.ephemeral, for: session.id)
                        } label: {
                            Label(session.ephemeral ? "Make permanent" : "Make ephemeral",
                                  systemImage: session.ephemeral ? "lock.open" : "eyeglasses")
                        }
                        .accessibilityIdentifier("ephemeralToggle")
                        Button {
                            let next: MemoryScope = session.memoryScope == .isolated ? .global : .isolated
                            orchestrator.setMemoryScope(next, for: session.id)
                        } label: {
                            Label(session.memoryScope == .isolated ? "Use global memory" : "Isolate memory",
                                  systemImage: session.memoryScope == .isolated ? "brain" : "brain.slash")
                        }
                        .accessibilityIdentifier("memoryScopeToggle")
                    }
                }
            }
            .navigationTitle("Chats")
            .searchable(text: $searchText, prompt: "Search chats")
            .overlay {
                if visibleSessions.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .onAppear(perform: consumePendingSearch)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .anuLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .anuTrailing) {
                    Button {
                        orchestrator.createSession()
                        dismiss()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                    .accessibilityIdentifier("newSessionButton")
                }
            }
            .alert("Rename chat", isPresented: renameBinding) {
                TextField("Name", text: $renameText)
                    .accessibilityIdentifier("renameSessionField")
                Button("Save") {
                    if let target = renameTarget {
                        orchestrator.renameSession(id: target.id, name: renameText)
                    }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
        }
    }

    @ViewBuilder
    private func row(_ session: ChatSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: Space.hair) {
                HStack(spacing: Space.tight) {
                    Text(session.name)
                        .font(.anuBody)
                        .lineLimit(1)
                    if session.ephemeral {
                        Image(systemName: "eyeglasses")
                            .font(.anuLabel)
                            .foregroundStyle(.secondary)
                    }
                    if session.memoryScope == .isolated {
                        Image(systemName: "brain.slash")
                            .font(.anuLabel)
                            .foregroundStyle(.secondary)
                    }
                }
                // "3 minutes ago" / "yesterday", not a ticking "3 min, 4 sec".
                Text(session.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.anuLabel)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if session.id == orchestrator.activeSessionID {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.anuAccent)
            }
        }
        .contentShape(Rectangle())
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
    }

    /// Picks up a term staged by `SearchAnuIntent` and clears it, so a Siri
    /// search lands in this list with the query already applied.
    private func consumePendingSearch() {
        let key = SearchAnuIntentKeys.pendingSearch
        guard let term = UserDefaults.standard.string(forKey: key), !term.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: key)
        searchText = term
    }

    private func startRename(_ session: ChatSession) {
        renameText = session.name
        renameTarget = session
    }
}
