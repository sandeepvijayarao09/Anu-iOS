import SwiftUI

/// The chat's title, and a menu of the models ready to run (AI Edge Gallery
/// switches models from its chat's top bar). Picking one swaps the brain
/// without leaving the chat; "More models…" opens Settings → Model.
struct ChatModelMenu: View {
    @ObservedObject private var manager = ModelManager.shared
    @ObservedObject private var orchestrator = AgentOrchestrator.shared
    let onMoreModels: () -> Void

    /// What the menu offers: models ready now, then your own imported ones.
    static func choices(_ options: [(option: ModelOption, availability: ModelAvailability)],
                        custom: [CustomModels.Model]) -> [(id: String, name: String)] {
        options.filter { $0.availability.isReady }.map { ($0.option.id, $0.option.displayName) }
            + custom.map { ($0.id, $0.name) }
    }

    var body: some View {
        Menu {
            Picker("Model", selection: Binding(
                get: { manager.selectedID },
                set: { id in
                    guard id != manager.selectedID else { return }
                    manager.select(id)
                    Task { await orchestrator.switchActiveModel() }
                })) {
                ForEach(Self.choices(manager.options, custom: CustomModels.list()), id: \.id) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }
            Divider()
            Button("More models…", systemImage: "square.stack.3d.up", action: onMoreModels)
        } label: {
            VStack(spacing: 0) {
                Text("Anu").font(.headline).foregroundStyle(Color.anuInk)
                HStack(spacing: 2) {
                    Text(ModelActivity.shortName(orchestrator.model.modelName))
                    Image(systemName: "chevron.down").imageScale(.small)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .disabled(orchestrator.isThinking)
        .accessibilityLabel("Model: \(ModelActivity.shortName(orchestrator.model.modelName))")
        .accessibilityHint("Switch the model that answers")
        .accessibilityIdentifier("chatModelMenu")
    }
}
