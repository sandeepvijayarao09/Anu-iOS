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

    var body: some View {
        NavigationStack {
            List {
                ForEach(orchestrator.sessions) { session in
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
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.name)
                        .font(.body)
                        .lineLimit(1)
                    if session.ephemeral {
                        Image(systemName: "eyeglasses")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if session.memoryScope == .isolated {
                        Image(systemName: "brain.slash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(session.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if session.id == orchestrator.activeSessionID {
                Image(systemName: "checkmark")
                    .foregroundStyle(.blue)
            }
        }
        .contentShape(Rectangle())
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
    }

    private func startRename(_ session: ChatSession) {
        renameText = session.name
        renameTarget = session
    }
}
