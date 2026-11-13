import SwiftUI

/// Saved Workflows: name a prompt recipe once, then re-run it from here, the
/// Share Sheet, a home-screen widget, Spotlight, "Hey Siri, run … in Anu," or a
/// scheduled reminder.
struct WorkflowsView: View {
    @ObservedObject private var manager = WorkflowManager.shared
    @State private var editor: WorkflowEditorTarget?
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            if manager.workflows.isEmpty {
                ContentUnavailableView {
                    Label("No workflows yet", systemImage: "play.square.stack")
                } description: {
                    Text("Save a prompt as a named, re-runnable action — then run it here, from the Share Sheet, a widget, Spotlight, “Hey Siri,” or on a schedule. Long-press a message in the chat to save it.")
                }
                .listRowBackground(Color.clear)
            } else {
                if manager.remindersBlocked {
                    Section {
                        remindersBlockedNotice
                    }
                }
                Section {
                    ForEach(manager.workflows) { workflow in
                        WorkflowRow(
                            workflow: workflow,
                            onRun: { manager.run(workflow) },
                            onEdit: { editor = .edit(workflow) }
                        )
                        .contextMenu {
                            Button { manager.run(workflow) } label: { Label("Run", systemImage: "play") }
                            Button { editor = .edit(workflow) } label: { Label("Edit", systemImage: "pencil") }
                            Button { manager.duplicate(id: workflow.id) } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                            Button(role: .destructive) { manager.delete(id: workflow.id) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete { manager.delete(at: $0) }
                    .onMove { manager.move(from: $0, to: $1) }
                } footer: {
                    Text("Running a workflow sends its prompt to the agent — watch it work in the chat, with approvals, receipts and the privacy ledger as usual. A scheduled workflow sends a reminder at its time; it runs when you tap it, never unattended.")
                }
            }
        }
        .navigationTitle("Workflows")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("workflowsView")
        .toolbar {
            ToolbarItem(placement: .anuTrailing) {
                Button {
                    editor = .add(prompt: "")
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

    private var remindersBlockedNotice: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Label("Reminders are off", systemImage: "bell.slash")
                .font(.anuBody.weight(.medium))
            Text("Scheduled workflows can’t remind you until notifications are allowed for Anu.")
                .font(.anuLabel).foregroundStyle(.secondary)
            #if os(iOS)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
            }
            .font(.anuLabel)
            #endif
        }
        .accessibilityIdentifier("remindersBlockedNotice")
    }
}

// MARK: - Row

private struct WorkflowRow: View {
    let workflow: Workflow
    let onRun: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: Space.base) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text(workflow.name).font(.anuBody.weight(.medium)).foregroundStyle(.primary)
                    Text(workflow.prompt)
                        .font(.anuLabel).foregroundStyle(.secondary).lineLimit(2)
                    if let meta = metaLine {
                        Text(meta)
                            .font(.anuLabel).foregroundStyle(.tertiary)
                            .padding(.top, Space.hair)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onRun) {
                Image(systemName: "play.circle.fill")
                    .font(.anuTitle)
                    .foregroundStyle(Color.anuAccent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("runWorkflowButton")
            .accessibilityLabel("Run \(workflow.name)")
        }
    }

    /// "Weekdays at 8:00 AM · Last run 2 hours ago"
    private var metaLine: String? {
        var parts: [String] = []
        if let schedule = workflow.schedule { parts.append(schedule.summary()) }
        if let last = workflow.lastRunAt {
            parts.append("Last run \(last.formatted(.relative(presentation: .named)))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Editor

/// What the editor sheet opens on: a new workflow (optionally prefilled, e.g.
/// from a chat message) or an existing one.
enum WorkflowEditorTarget: Identifiable {
    case add(prompt: String)
    case edit(Workflow)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let w): return w.id.uuidString
        }
    }
}

struct WorkflowEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = WorkflowManager.shared
    let target: WorkflowEditorTarget

    @State private var name: String
    @State private var prompt: String
    @State private var isScheduled: Bool
    @State private var schedule: WorkflowSchedule

    init(target: WorkflowEditorTarget) {
        self.target = target
        switch target {
        case .add(let prompt):
            _name = State(initialValue: "")
            _prompt = State(initialValue: prompt)
            _isScheduled = State(initialValue: false)
            _schedule = State(initialValue: WorkflowSchedule())
        case .edit(let w):
            _name = State(initialValue: w.name)
            _prompt = State(initialValue: w.prompt)
            _isScheduled = State(initialValue: w.schedule != nil)
            _schedule = State(initialValue: w.schedule ?? WorkflowSchedule())
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !prompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The schedule's hour and minute as a `Date` for the time picker.
    private var time: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute,
                                      second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                schedule.hour = comps.hour ?? schedule.hour
                schedule.minute = comps.minute ?? schedule.minute
            }
        )
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
                Section {
                    Toggle("Remind me to run it", isOn: $isScheduled.animation())
                        .accessibilityIdentifier("workflowScheduleToggle")
                    if isScheduled {
                        Picker("Repeat", selection: $schedule.repeats) {
                            ForEach(WorkflowSchedule.Repeat.allCases) { Text($0.label).tag($0) }
                        }
                        .accessibilityIdentifier("workflowRepeatPicker")
                        if schedule.repeats == .weekly {
                            Picker("Day", selection: $schedule.weekday) {
                                ForEach(1...7, id: \.self) { day in
                                    Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                                }
                            }
                        }
                        DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                            .accessibilityIdentifier("workflowTimePicker")
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    if isScheduled {
                        Text("\(schedule.summary()), Anu sends a notification. Tap it to run the workflow. iOS can’t run an on-device model in the background on a timer, so nothing runs until you tap.")
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Workflow" : "New Workflow")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .anuLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .anuTrailing) {
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
        let savedSchedule = isScheduled ? schedule : nil
        switch target {
        case .add:
            manager.add(name: trimmedName, prompt: trimmedPrompt, schedule: savedSchedule)
        case .edit(let w):
            manager.update(Workflow(id: w.id, name: trimmedName, prompt: trimmedPrompt,
                                    schedule: savedSchedule, lastRunAt: w.lastRunAt))
        }
        dismiss()
    }
}
