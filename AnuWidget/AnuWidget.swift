import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline

/// Reads the saved workflows from the App Group so the widget shows the same
/// list the app does. No model code here — tapping a workflow enqueues it via
/// `RunWorkflowIntent` and opens the app, which runs it.
struct WorkflowEntry: TimelineEntry {
    let date: Date
    let workflows: [Workflow]
}

struct WorkflowProvider: TimelineProvider {
    private func current() -> [Workflow] {
        Array(WorkflowStore().load().prefix(4))
    }

    func placeholder(in context: Context) -> WorkflowEntry {
        WorkflowEntry(date: Date(), workflows: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (WorkflowEntry) -> Void) {
        completion(WorkflowEntry(date: Date(), workflows: current()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WorkflowEntry>) -> Void) {
        // The list only changes when the user edits it (and edits reload the
        // timeline via WidgetCenter), so a single never-expiring entry is enough.
        completion(Timeline(entries: [WorkflowEntry(date: Date(), workflows: current())], policy: .never))
    }
}

// MARK: - View

struct AnuWidgetEntryView: View {
    var entry: WorkflowEntry
    @Environment(\.widgetFamily) private var family

    private var limit: Int { family == .systemSmall ? 2 : 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "brain").foregroundStyle(.blue)
                Text("Anu").font(.caption.bold())
            }

            if entry.workflows.isEmpty {
                Text("Save a workflow in the app to run it from here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("Tap to open")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
            } else {
                ForEach(entry.workflows.prefix(limit)) { workflow in
                    Button(intent: RunWorkflowIntent(workflow: WorkflowEntity(workflow))) {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill").font(.caption2)
                            Text(workflow.name).font(.caption2).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Widget

struct AnuWidget: Widget {
    let kind = "AnuWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WorkflowProvider()) { entry in
            AnuWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Anu Workflows")
        .description("Run a saved workflow, or tap to open the agent.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct AnuWidgetBundle: WidgetBundle {
    var body: some Widget {
        AnuWidget()
    }
}
