import SwiftUI

// MARK: - Activity

/// Every action Anu took or was stopped from taking, newest first — the Tool
/// Broker's audit, kept on this device (Settings → Activity).
struct ActivityView: View {
    @ObservedObject var log: ToolAuditLog = .shared
    @State private var confirmClear = false

    var body: some View {
        List {
            if log.entries.isEmpty {
                Text("Nothing yet. When Anu uses a tool — reads your calendar, sets a timer, asks before texting someone — it's listed here.")
                    .font(.anuSecondary)
                    .foregroundStyle(.secondary)
            }
            ForEach(log.entries) { entry in
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(entry.summary)
                        .font(.anuBody)
                        .foregroundStyle(Color.anuInk)
                    HStack(spacing: Space.tight) {
                        if let destination = entry.destination {
                            Circle().fill(.orange).frame(width: 6, height: 6)
                            Text(destination)
                        }
                        Text(Self.outcomeLabel(entry))
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.anuMeta)
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            if !log.entries.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear", role: .destructive) { confirmClear = true }
                        .accessibilityIdentifier("clearActivityButton")
                }
            }
        }
        .confirmationDialog("Clear all activity?", isPresented: $confirmClear) {
            Button("Clear Activity", role: .destructive) { log.clear() }
        }
        .accessibilityIdentifier("activityList")
    }

    /// "Approved · ok", "Declined", "Ran by itself · ok".
    static func outcomeLabel(_ entry: ToolAuditEntry) -> String {
        switch entry.approved {
        case .some(true): return "Approved · \(entry.outcome)"
        case .some(false): return entry.outcome.prefix(1).uppercased() + entry.outcome.dropFirst()
        case .none: return entry.risk == .read ? entry.outcome : "Ran by itself · \(entry.outcome)"
        }
    }
}
