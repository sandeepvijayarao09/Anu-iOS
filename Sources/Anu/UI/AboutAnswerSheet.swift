import SwiftUI

/// The caption under an answer (ADR-071): the model that answered and the
/// time. With saved details it's a button that opens About this answer; an
/// answer saved before details were kept has a plain caption.
struct AnswerCaption: View {
    let message: AgentMessage
    @State private var showingAbout = false

    var body: some View {
        let time = message.timestamp.formatted(date: .omitted, time: .shortened)
        if let details = message.details {
            Button {
                showingAbout = true
            } label: {
                HStack(spacing: Space.xs) {
                    Text("\(AnswerDetailsText.caption(details)) · \(time)")
                    Image(systemName: "info.circle")
                }
                .font(.anuMeta)
                .foregroundStyle(.secondary)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(AnswerDetailsText.caption(details)), \(time)")
            .accessibilityHint("Opens About this answer")
            .accessibilityIdentifier("answerCaption")
            .sheet(isPresented: $showingAbout) {
                AboutAnswerSheet(details: details, receipts: message.receipts ?? [])
            }
        } else {
            Text(time)
                .font(.anuMeta)
                .foregroundStyle(.tertiary)
        }
    }
}

/// The model's reasoning, collapsed under the answer (ADR-077). It's never
/// part of the answer: not saved into the model's history, not read aloud.
struct ReasoningDisclosure: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.anuLabel)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Space.xs)
        } label: {
            Text("Thought it through")
                .font(.anuLabel)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.comfy)
        .accessibilityIdentifier("reasoningDisclosure")
    }
}

/// About this answer: where your data went first, then the model and where it
/// ran, what it was given and did, and how fast it was.
struct AboutAnswerSheet: View {
    let details: AnswerDetails
    let receipts: [ActionReceipt]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text(AnswerDetailsText.whereItWent(details))
                    } icon: {
                        Image(systemName: details.leftDevice ? "arrow.up.right.circle" : "lock.circle")
                            .foregroundStyle(details.leftDevice ? Color.orange : Color.green)
                    }
                    .accessibilityIdentifier("aboutWhere")
                    Label(AnswerDetailsText.whoAnswered(details), systemImage: "cpu")
                        .accessibilityIdentifier("aboutWho")
                    if let route = details.route {
                        LabeledContent("Path", value: route)
                    }
                }

                if AnswerDetailsText.memory(details) != nil || !(details.toolsUsed ?? []).isEmpty || !receipts.isEmpty {
                    Section("What it used and did") {
                        if let memory = AnswerDetailsText.memory(details) {
                            Label(memory, systemImage: "brain.head.profile")
                        }
                        if let tools = details.toolsUsed, !tools.isEmpty {
                            Label(tools.joined(separator: ", "), systemImage: "wrench.and.screwdriver")
                        }
                        ForEach(receipts) { receipt in
                            Label {
                                Text(receipt.summary) + Text(" · " + receipt.statusLabel).foregroundStyle(.secondary)
                            } icon: {
                                Image(systemName: ReceiptList.icon(receipt.status))
                            }
                        }
                    }
                }

                let rows = AnswerDetailsText.speedRows(details)
                if !rows.isEmpty {
                    Section {
                        ForEach(rows, id: \.label) { row in
                            LabeledContent(row.label) {
                                Text(row.value).font(.anuCode)
                            }
                        }
                    } header: {
                        Text("Speed")
                    } footer: {
                        if details.tier == .onDevice, details.counted == false {
                            Text("“About” marks estimates: this model didn't report its own token counts.")
                        }
                    }
                }
            }
            .navigationTitle("About this answer")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .anuTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("aboutAnswerSheet")
    }
}
