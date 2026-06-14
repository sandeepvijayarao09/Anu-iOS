import SwiftUI

/// See and edit everything Gemma remembers. Notes here are the sources
/// responses get grounded in (NotebookLM-style).
struct MemoryView: View {
    @ObservedObject private var store = MemoryStore.shared
    @State private var newNote = ""
    @State private var editingNote: MemoryNote?

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Add something to remember…", text: $newNote, axis: .vertical)
                        .lineLimit(1...3)
                        .accessibilityIdentifier("newMemoryField")
                    Button {
                        let trimmed = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        store.add(trimmed)
                        newNote = ""
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .disabled(newNote.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Save memory")
                }
            } footer: {
                Text("You can also say \"remember …\" in chat. Gemma grounds its answers in these notes and cites them like [M1].")
            }

            Section {
                if store.notes.isEmpty {
                    Text("Nothing remembered yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.notes) { note in
                        Button {
                            editingNote = note
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(note.content)
                                    .foregroundStyle(.primary)
                                Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            store.delete(id: store.notes[index].id)
                        }
                    }
                }
            } header: {
                Text("\(store.notes.count) memor\(store.notes.count == 1 ? "y" : "ies")")
            }

            if !store.notes.isEmpty {
                Section {
                    Button("Forget Everything", role: .destructive) {
                        store.deleteAll()
                    }
                }
            }
        }
        .navigationTitle("Memory")
        .sheet(item: $editingNote) { note in
            MemoryEditSheet(note: note)
        }
    }
}

private struct MemoryEditSheet: View {
    let note: MemoryNote
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Memory", text: $text, axis: .vertical)
                    .lineLimit(3...10)
            }
            .navigationTitle("Edit Memory")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        MemoryStore.shared.update(
                            id: note.id,
                            content: text.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { text = note.content }
        }
    }
}
