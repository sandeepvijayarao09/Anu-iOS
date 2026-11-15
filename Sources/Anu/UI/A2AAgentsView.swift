import SwiftUI

/// Settings → Connectors → Agents on your network (A2A, ADR-105): add, list and
/// remove agents by address. Each becomes a tool that asks before every message.
struct A2AAgentsView: View {
    @ObservedObject private var agents = A2AAgents.shared
    @State private var newAddress = ""
    @State private var problem = ""
    @State private var isRefreshing = false

    var body: some View {
        Form {
            Section {
                TextField("http://raspberrypi.local:8768", text: $newAddress)
                    .textFieldStyle(.plain)
                    .anuURLField()
                    .accessibilityIdentifier("a2aAddressField")
                    .onSubmit { add() }
                Button("Add agent") { add() }
                    .disabled(newAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("a2aAddButton")
                if !problem.isEmpty {
                    Text(problem).font(.anuLabel).foregroundStyle(.red)
                }
            } header: {
                Text("Add an agent")
            } footer: {
                Text("The agent's address. Anu reads its card at /.well-known/agent-card.json (or the older agent.json). Plain HTTP works only on your own network.")
            }

            Section {
                if agents.addresses.isEmpty {
                    Text("No agents yet.").foregroundStyle(.secondary)
                }
                ForEach(agents.addresses, id: \.self) { address in
                    row(address)
                }
                .onDelete { offsets in
                    offsets.map { agents.addresses[$0] }.forEach(agents.remove)
                    reload()
                }
                Button {
                    reload()
                } label: {
                    HStack {
                        if isRefreshing { ProgressView().scaleEffect(0.8).padding(.trailing, Space.xs) }
                        Text(isRefreshing ? "Checking…" : "Check agents")
                    }
                }
                .disabled(agents.addresses.isEmpty || isRefreshing)
            } header: {
                Text("Agents")
            } footer: {
                Text("Every message to an agent waits for you to approve the exact words, and is recorded in the Privacy Ledger. What an agent answers was written by another program, so Anu asks before any later action in that request.")
            }
        }
        .navigationTitle("Agents on your network")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        #endif
        .accessibilityIdentifier("a2aAgentsView")
    }

    @ViewBuilder
    private func row(_ address: String) -> some View {
        let agent = agents.agents.first { $0.address == address }
        VStack(alignment: .leading, spacing: Space.hair) {
            Text(agent?.name ?? address)
            if let agent {
                Text("\(agent.host) · \(A2AAgentTool.toolName(agent.name))")
                    .font(.anuLabel).foregroundStyle(.secondary).lineLimit(1)
                if !agent.skills.isEmpty {
                    Text(agent.skills.joined(separator: ", "))
                        .font(.anuLabel).foregroundStyle(.secondary).lineLimit(2)
                }
            } else if let why = agents.problems[address] {
                Text(why).font(.anuLabel).foregroundStyle(.red).lineLimit(2)
            } else {
                Text("Not checked yet").font(.anuLabel).foregroundStyle(.secondary)
            }
        }
    }

    private func add() {
        do {
            try agents.add(newAddress)
            newAddress = ""
            problem = ""
            reload()
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func reload() {
        isRefreshing = true
        Task {
            // Re-reads every card and re-registers the agents' tools.
            await AgentOrchestrator.shared.reloadConnectors()
            isRefreshing = false
        }
    }
}
