import SwiftUI

/// Saved Workflows: name a prompt recipe once, then re-run it from here, the
/// Share Sheet, a home-screen widget, or "Hey Siri, run … in Anu." The
/// first taste of automation — the bridge toward scheduling/triggers in v1.
struct WorkflowsView: View {
    @ObservedObject private var manager = WorkflowManager.shared
    @State private var editor: EditorTarget?

    var body: some View {
        List {
            if manager.workflows.isEmpty {
                ContentUnavailableView {
                    Label("No workflows yet", systemImage: "play.square.stack")
                } description: {
                    Text("Save a prompt as a named, re-runnable action — then run it here, from the Share Sheet, a widget, or “Hey Siri.”")
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(manager.workflows) { workflow in
                        WorkflowRow(
                            workflow: workflow,
                            onRun: { run(workflow) },
                            onEdit: { editor = .edit(workflow) }
                        )
                    }
                    .onDelete { manager.delete(at: $0) }
                } footer: {
                    Text("Running a workflow sends its prompt to the agent — watch it work in the chat, with the glass-box trace and privacy ledger as usual.")
                }
            }
        }
        .navigationTitle("Workflows")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("workflowsView")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editor = .add
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("addWorkflowButton")
                .accessibilityLabel("Add workflow")
            }
        }
        .sheet(item: $editor) { target in
            WorkflowEditor(target: target)
        }
    }

    private func run(_ workflow: Workflow) {
        Task { await AgentOrchestrator.shared.run(userMessage: workflow.prompt) }
    }
}

// MARK: - Row

private struct WorkflowRow: View {
    let workflow: Workflow
    let onRun: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workflow.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(workflow.prompt)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onRun) {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("runWorkflowButton")
            .accessibilityLabel("Run \(workflow.name)")
        }
    }
}

// MARK: - Editor

private enum EditorTarget: Identifiable {
    case add
    case edit(Workflow)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let w): return w.id.uuidString
        }
    }
}

private struct WorkflowEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = WorkflowManager.shared
    let target: EditorTarget

    @State private var name: String
    @State private var prompt: String

    init(target: EditorTarget) {
        self.target = target
        switch target {
        case .add:
            _name = State(initialValue: "")
            _prompt = State(initialValue: "")
        case .edit(let w):
            _name = State(initialValue: w.name)
            _prompt = State(initialValue: w.prompt)
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !prompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Morning briefing", text: $name)
                        .accessibilityIdentifier("workflowNameField")
                }
                Section {
                    TextField("What should the agent do?", text: $prompt, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("workflowPromptField")
                } header: {
                    Text("Prompt")
                } footer: {
                    Text("This prompt runs exactly as if you typed it — it can use any connector or tool you've enabled.")
                }
            }
            .navigationTitle(isEditing ? "Edit Workflow" : "New Workflow")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("saveWorkflowButton")
                }
            }
        }
    }

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case .add:
            manager.add(name: trimmedName, prompt: trimmedPrompt)
        case .edit(let w):
            manager.update(Workflow(id: w.id, name: trimmedName, prompt: trimmedPrompt))
        }
        dismiss()
    }
}
