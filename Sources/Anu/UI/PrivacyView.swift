import SwiftUI

/// The Privacy Ledger screen: a chronological log of every outbound event, so
/// the user can see exactly what left the device (and what stayed private).
/// Reached from Settings → Privacy and by tapping the per-turn chip in the chat.
struct PrivacyView: View {
    @ObservedObject private var ledger = PrivacyLedger.shared
    @Environment(\.dismiss) private var dismiss
    /// True when presented as a sheet (from the chip) — adds a Done button.
    var isModal: Bool = false

    @State private var expanded: Set<UUID> = []

    private var events: [PrivacyEvent] { ledger.events.reversed() }

    var body: some View {
        List {
            Section {
                SummaryCard(totals: ledger.sessionTotals)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if events.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Nothing has left this device",
                        systemImage: "lock.shield",
                        description: Text("When the agent sends anything to the cloud, an MCP server, a REST API, or another app, it's logged here.")
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section("Outbound events") {
                    ForEach(events) { event in
                        EventRow(
                            event: event,
                            isExpanded: expanded.contains(event.id)
                        ) {
                            withAnimation(.spring(duration: 0.25)) {
                                if expanded.contains(event.id) { expanded.remove(event.id) }
                                else { expanded.insert(event.id) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Privacy")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("privacyView")
        .toolbar {
            if isModal {
                ToolbarItem(placement: .anuLeading) {
                    Button("Done") { dismiss() }
                }
            }
            if !ledger.events.isEmpty {
                ToolbarItem(placement: .anuTrailing) {
                    Button(role: .destructive) {
                        ledger.clear()
                        expanded.removeAll()
                    } label: {
                        Text("Clear")
                    }
                    .accessibilityIdentifier("clearLedgerButton")
                }
            }
        }
    }
}

// MARK: - Summary card

private struct SummaryCard: View {
    let totals: (events: Int, offDevice: Int, redactions: Int, bytes: Int)

    var body: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            HStack(spacing: Space.snug) {
                Image(systemName: totals.offDevice == 0 ? "lock.shield.fill" : "shield.lefthalf.filled")
                    .foregroundStyle(totals.offDevice == 0 ? .green : .orange)
                Text(totals.offDevice == 0 ? "Everything stayed on this device" : "What left this device")
                    .font(.anuHeading)
            }
            HStack(spacing: Space.comfy) {
                stat("\(totals.offDevice)", "left device")
                stat("\(totals.redactions)", "redacted")
                stat(ByteCountFormatter.string(fromByteCount: Int64(totals.bytes), countStyle: .file), "sent")
            }
        }
        .padding(Space.comfy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.anuGroupedBackgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Radius.medium))
        .padding(.horizontal)
        .padding(.top, Space.xs)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            Text(value).font(.anuTitle.monospacedDigit())
            Text(label).font(.anuLabel).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Event row

private struct EventRow: View {
    let event: PrivacyEvent
    let isExpanded: Bool
    let onTap: () -> Void

    private var accent: Color {
        event.destination.leavesDevice ? .orange : Color.anuAccent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Button(action: onTap) {
                HStack(alignment: .top, spacing: Space.base) {
                    ZStack {
                        Circle().fill(accent.opacity(0.15)).frame(width: 30, height: 30)
                        Image(systemName: event.destination.iconName)
                            .font(.system(size: 13))
                            .foregroundStyle(accent)
                    }
                    VStack(alignment: .leading, spacing: Space.hair) {
                        Text(event.destination.displayName)
                            .font(.anuSecondary)
                            .foregroundStyle(.primary)
                        Text(event.destination.detail)
                            .font(.anuLabel)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: Space.tight) {
                            Pill(text: event.destination.leavesDevice ? "Off device" : "On device",
                                 color: event.destination.leavesDevice ? .orange : .green)
                            if event.redactions > 0 {
                                Pill(text: "\(event.redactions) redacted", color: .secondary)
                            }
                            Text(event.timestamp, style: .time)
                                .font(.anuMeta)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.anuLabel)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("PAYLOAD SENT")
                        .font(.anuLabelStrong)
                        .foregroundStyle(.secondary)
                        .tracking(1)
                    Text(event.payloadSummary.isEmpty ? "(empty)" : event.payloadSummary)
                        .font(.anuCode)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.snug)
                        .background(accent.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                }
                .padding(.leading, Space.stage)
            }
        }
        .padding(.vertical, Space.hair)
    }
}

private struct Pill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.anuLabelStrong)
            .foregroundStyle(color)
            .padding(.horizontal, Space.tight)
            .padding(.vertical, Space.hair)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - Per-turn chip (chat surface)

/// Compact "what left your device" indicator shown under the chat after each
/// turn. Green when nothing left the device; amber with a one-line summary when
/// something did. Tapping opens the full Privacy ledger.
struct PrivacyChip: View {
    let summary: TurnEgressSummary
    let onTap: () -> Void

    private var leftDevice: Bool { !summary.nothingLeftDevice }

    private var tint: Color { leftDevice ? .orange : .green }

    private var icon: String { leftDevice ? "arrow.up.circle.fill" : "lock.shield.fill" }

    private var label: String {
        guard leftDevice else { return "0 bytes left this device" }
        if summary.destinations.contains(where: { if case .cloud = $0 { return true } else { return false } }) {
            let base = "Sent sanitized task to Gemini"
            return summary.redactions > 0 ? "\(base) · \(summary.redactions) redacted" : base
        }
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(summary.byteCount), countStyle: .file)
        let n = summary.offDeviceEvents
        return "\(n) call\(n == 1 ? "" : "s") left this device · \(bytes)"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Space.tight) {
                Image(systemName: icon)
                Text(label)
                    .font(.anuLabel)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.anuLabel)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, Space.base)
            .padding(.vertical, Space.snug)
            .frame(maxWidth: .infinity)
            .background(tint.opacity(0.10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("privacyChip")
        .accessibilityLabel(label)
    }
}
