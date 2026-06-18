import SwiftUI

/// Model Manager: see every brain the app can run and pick the active one —
/// including Apple's own on-device model. Selecting a ready model swaps it in
/// place via `AgentOrchestrator.switchActiveModel()` (no relaunch).
struct ModelManagerView: View {
    @ObservedObject private var manager = ModelManager.shared

    var body: some View {
        List {
            section("Recommended", kinds: [.automatic])
            section("On this device", kinds: [.liteRT, .coreML])
            section("Apple", kinds: [.appleFoundation], footer:
                "Apple's on-device model, behind the same protocol as every other brain — no special-casing.")
            section("Downloadable", kinds: [.downloadable], footer:
                "Curated open models. A download manager is coming in a future build; for now these are listed to show the app isn't locked to one model.")
            section("Private", kinds: [.privateCloud], footer:
                "Runs on the private compute server you operate. Selecting it as your default sends every prompt off-device — the Privacy Ledger records this. Configure it in Settings → Private Compute.")
        }
        .navigationTitle("Model")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("modelManagerView")
    }

    @ViewBuilder
    private func section(_ title: String, kinds: Set<ModelBackendKind>, footer: String? = nil) -> some View {
        let rows = manager.options.filter { kinds.contains($0.option.kind) }
        Section {
            ForEach(rows, id: \.option.id) { entry in
                ModelRow(
                    option: entry.option,
                    availability: entry.availability,
                    isSelected: entry.option.id == manager.selectedID
                ) {
                    manager.select(entry.option.id)
                    Task { await AgentOrchestrator.shared.switchActiveModel() }
                }
            }
        } header: {
            Text(title)
        } footer: {
            if let footer { Text(footer) }
        }
    }
}

// MARK: - Row

private struct ModelRow: View {
    let option: ModelOption
    let availability: ModelAvailability
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(option.displayName).font(.body.weight(.medium))
                        Text(option.family).font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color(.systemGray6))
                            .clipShape(Capsule())
                    }
                    Text("\(option.sizeText) · \(option.ramText) · \(option.speedText)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    statusLine
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                        .accessibilityLabel("Active model")
                }
            }
            .contentShape(Rectangle())
            .opacity(availability.isReady ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(!availability.isReady)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch availability {
        case .ready:
            EmptyView()
        case .needsDownload:
            Label("Download manager coming soon", systemImage: "arrow.down.circle")
                .font(.caption2).foregroundStyle(.tertiary)
        case .unsupported(let reason):
            Label(reason, systemImage: "exclamationmark.circle")
                .font(.caption2).foregroundStyle(.orange)
        }
    }
}
