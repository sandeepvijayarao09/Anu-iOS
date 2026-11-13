import SwiftUI
import UIKit

/// The "Rewrite with Anu" sheet: six actions, the user's own instruction, a
/// preview, then Replace or Copy.
struct WritingActionView: View {
    @ObservedObject var model: WritingActionModel
    @State private var copied = false
    @FocusState private var instructionFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Selected text") {
                    Text(model.original.isEmpty ? "No text" : model.original)
                        .lineLimit(6)
                        .foregroundStyle(.secondary)
                }
                content
            }
            .navigationTitle("Rewrite with Anu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.close() }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .choosing:
            actions
        case .working(let label):
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("\(label)…")
                }
            } footer: { onDeviceFooter(model.engine?.name ?? "") }
        case .preview(let text, let label, let engine):
            Section {
                Text(text).textSelection(.enabled)
            } header: {
                Text(label)
            } footer: {
                onDeviceFooter(engine)
            }
            Section {
                Button {
                    model.replace()
                } label: { Label("Replace", systemImage: "arrow.left.arrow.right") }
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                } label: { Label(copied ? "Copied" : "Copy", systemImage: "doc.on.doc") }
                Button("Try another") { copied = false; model.back() }
            } footer: {
                Text("Replace hands the text back to the app you came from, where it accepts it. If nothing changes there, use Copy and paste.")
            }
        case .handedOff(let label):
            Section {
                Label("\(label) is waiting for Anu", systemImage: "tray.and.arrow.down")
            } footer: {
                Text("Open the Anu app: it writes this on its own on-device model, nothing goes to the cloud, and the result is kept for 15 minutes. Then open Rewrite with Anu on the same text to Replace it, or copy it in Anu.")
            }
            Section { Button("Done") { model.close() } }
        case .offerHandOff(let text):
            Section {
                Text(text)
                Button {
                    model.handOff()
                } label: { Label("Hand to Anu", systemImage: "arrow.up.forward.app") }
                Button("Back") { model.back() }
            } footer: {
                Text("Only Anu's own on-device model sees it. Nothing goes to the cloud.")
            }
        case .note(let text):
            Section {
                Text(text)
                if !model.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Back") { model.back() }
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        Section {
            ForEach(WritingAction.allCases) { action in
                Button {
                    model.run(action)
                } label: { Label(action.label, systemImage: action.symbol) }
            }
        } footer: {
            if model.engine == nil {
                Text(model.handOffPrompt)
            }
        }
        Section("Or say what to do") {
            TextField("Make it sound like a pirate", text: $model.instruction, axis: .vertical)
                .focused($instructionFocused)
                .submitLabel(.go)
                .onSubmit { model.runInstruction() }
            Button("Go") { model.runInstruction() }
                .disabled(model.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func onDeviceFooter(_ engine: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(.green).frame(width: 7, height: 7)
            Text(engine.isEmpty ? "On this device" : "On this device · \(engine)")
        }
    }
}
