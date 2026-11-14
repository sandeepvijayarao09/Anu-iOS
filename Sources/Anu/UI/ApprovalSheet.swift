import SwiftUI

// MARK: - Approval sheet

/// Asks the user to approve one tool call. It shows the exact payload the
/// broker will run — never the model's paraphrase — where it goes, and why it
/// asks. Fields the tool allows can be edited; saving an edit approves nothing:
/// the broker checks it and asks again with exactly what will run (I2).
struct ApprovalSheet: View {
    let request: ApprovalRequest
    let onDecide: (ApprovalDecision) -> Void

    @State private var isEditing = false
    @State private var draft: [String: String] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.comfy) {
                    header
                    if request.tainted { taintNotice }
                    if let problem = request.problem {
                        Label(problem, systemImage: "exclamationmark.circle")
                            .font(.anuLabel)
                            .foregroundStyle(Color.anuDestructive)
                            .accessibilityIdentifier("approvalProblem")
                    }
                    if isEditing { editor } else { payloadRows }
                }
                .padding(Space.comfy)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(isEditing ? "Edit" : "Approve this?")
            #if os(iOS)
            // Inline, so the payload — not the title — gets the space.
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if isEditing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isEditing = false }
                            .accessibilityIdentifier("cancelEditButton")
                    }
                } else if !request.editableFields.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit") { startEditing() }
                            .accessibilityIdentifier("editApprovalButton")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { actions }
        }
        // Tall enough that the whole payload shows without scrolling.
        .presentationDetents([.fraction(0.62), .large])
        // Solid, not glass: this is the one place the exact payload must read
        // cleanly, with nothing from the chat blurring through behind it.
        .presentationBackground(.background)
        // The run is waiting on an answer; swiping the sheet away would leave
        // it guessing. Decline is one tap.
        .interactiveDismissDisabled()
        .accessibilityIdentifier("approvalSheet")
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            Text(request.summary)
                .font(.anuHeading)
                .foregroundStyle(Color.anuInk)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("approvalSummary")
            Label(request.reason, systemImage: request.destination == nil ? "person.2" : "arrow.up.forward.circle")
                .font(.anuSecondary)
                .foregroundStyle(.secondary)
            if let destination = request.destination {
                HStack(spacing: Space.tight) {
                    Circle().fill(.orange).frame(width: 8, height: 8)
                    Text("Goes to \(destination)")
                        .font(.anuLabel)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if request.edited {
                Text("Edited by you")
                    .font(.anuLabelStrong)
                    .padding(.horizontal, Space.snug)
                    .padding(.vertical, Space.hair)
                    .background(Color.anuFill6, in: Capsule())
                    .accessibilityIdentifier("editedBadge")
            }
        }
    }

    private var taintNotice: some View {
        Label {
            Text("This request read content written by others, such as a web page, a calendar invite or a service's reply. Check the details closely: text like that can try to steer Anu.")
                .font(.anuLabel)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.shield")
        }
        .foregroundStyle(.secondary)
        .anuCard()
        .accessibilityIdentifier("taintNotice")
    }

    /// The exact payload, field by field.
    private var payloadRows: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            ForEach(Self.fields(of: request.payload), id: \.key) { field in
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(label(for: field.key))
                        .font(.anuLabelStrong)
                        .foregroundStyle(.secondary)
                    Text(field.value)
                        .font(field.isStructured ? .anuCode : .anuBody)
                        .foregroundStyle(Color.anuInk)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .anuCard()
        .accessibilityIdentifier("approvalPayload")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            ForEach(request.editableFields, id: \.key) { field in
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(field.optional ? "\(field.label) (optional)" : field.label)
                        .font(.anuLabelStrong)
                        .foregroundStyle(.secondary)
                    switch field.kind {
                    case .line:
                        TextField(field.label, text: binding(for: field.key))
                            .textFieldStyle(.roundedBorder)
                    case .text:
                        TextEditor(text: binding(for: field.key))
                            .frame(minHeight: 96)
                            .overlay(RoundedRectangle(cornerRadius: Radius.small).stroke(Color.anuHairline))
                    }
                }
                .accessibilityIdentifier("editField_\(field.key)")
            }
            Text("Only these fields can change. Anu checks your edit and shows it to you again before anything runs.")
                .font(.anuMeta)
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: Space.base) {
            if isEditing {
                Button {
                    onDecide(.revised(editedPayload()))
                } label: {
                    Text("Save changes").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("saveEditButton")
            } else {
                Button(role: .cancel) {
                    onDecide(.denied)
                } label: {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("declineButton")

                Button {
                    onDecide(.approved)
                } label: {
                    Text("Approve").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("approveButton")
            }
        }
        .controlSize(.large)
        .padding(Space.comfy)
        .background(.bar)
    }

    // MARK: Editing

    private func startEditing() {
        draft = Dictionary(uniqueKeysWithValues: request.editableFields.map { field in
            (field.key, request.payload[field.key]?.stringValue ?? "")
        })
        isEditing = true
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(get: { draft[key] ?? "" }, set: { draft[key] = $0 })
    }

    /// The approved payload with the user's text in the editable fields.
    private func editedPayload() -> JSONValue {
        var object = request.payload.objectValue ?? [:]
        for field in request.editableFields {
            object[field.key] = .string(draft[field.key] ?? "")
        }
        return .object(object)
    }

    private func label(for key: String) -> String {
        request.editableFields.first(where: { $0.key == key })?.label
            ?? key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Payload fields in a stable order, as text. `internal` for tests.
    static func fields(of payload: JSONValue) -> [(key: String, value: String, isStructured: Bool)] {
        guard let object = payload.objectValue else { return [] }
        return object.keys.sorted().compactMap { key in
            guard let value = object[key], !value.isNull else { return nil }
            switch value {
            case .array, .object: return (key, value.prettyJSON, true)
            default: return (key, ToolDescribing.short(value, limit: 4_000), false)
            }
        }
    }
}
