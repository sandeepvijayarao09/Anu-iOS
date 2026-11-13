import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The Notes page's state: the store's notes, reloaded whenever they change.
@MainActor
final class NotesModel: ObservableObject {
    @Published private(set) var notes: [Note] = []
    @Published var query = ""
    @Published var problem: String?
    let store: NoteStore
    private var observer: NSObjectProtocol?

    init(store: NoteStore = .shared) {
        self.store = store
        reload()
        observer = NotificationCenter.default.addObserver(forName: .anuNotesChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() { notes = store.all }

    var shown: [Note] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? notes : store.search(query, limit: NoteStore.maxNotes)
    }

    /// Saves an edit (or a new note when `id` is nil). True when it was saved.
    func save(id: UUID?, title: String, text: String) -> Bool {
        do {
            if let id { try store.update(id: id, title: title, text: text) } else { try store.add(title: title, text: text) }
            problem = nil
            reload()
            return true
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "The note wasn't saved."
            return false
        }
    }

    func delete(_ note: Note) {
        store.delete(id: note.id)
        reload()
    }

    /// The share sheet handed a note to another app: say so in the privacy
    /// ledger, as any other hand-off out of Anu. The share sheet itself stays
    /// on the phone; what the receiving app does next is up to that app.
    static func recordShare(_ note: Note, to activity: String) {
        PrivacyLedger.shared.record(destination: .appLaunch(scheme: "share sheet", target: activity),
                                    payload: NoteStore.shareText(note), redactions: 0)
    }
}

/// Settings → Notes: the notes Anu keeps for you (ADR-093). Add, edit,
/// delete, search, and Share to Notes (or any app) through the share sheet.
struct NotesView: View {
    @StateObject private var model = NotesModel()
    @State private var editing: NoteDraft?

    var body: some View {
        List {
            if model.notes.isEmpty {
                Section {
                    Text("Ask Anu to “make a note…” or tap + to add one. Notes stay on this phone, encrypted. Share a note to put it in Apple Notes or any other app.")
                        .font(.anuMeta)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.shown) { note in
                Button { editing = NoteDraft(note) } label: { NoteRow(note: note) }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) { model.delete(note) } label: { Label("Delete", systemImage: "trash") }
                    }
                    .contextMenu {
                        NoteShareButton(note: note)
                        Button(role: .destructive) { model.delete(note) } label: { Label("Delete", systemImage: "trash") }
                    }
                    .accessibilityIdentifier("noteRow")
            }
        }
        .searchable(text: $model.query, prompt: "Search notes")
        .navigationTitle("Notes")
        .toolbar {
            ToolbarItem(placement: .anuTrailing) {
                Button { editing = NoteDraft(nil) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New note")
                    .accessibilityIdentifier("addNoteButton")
            }
        }
        .sheet(item: $editing) { draft in
            NoteEditor(draft: draft, model: model) { editing = nil }
        }
    }
}

/// What the editor works on: a copy of the note, or a blank one.
struct NoteDraft: Identifiable {
    let id = UUID()
    let note: Note?
    init(_ note: Note?) { self.note = note }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(note.title).font(.anuLabel).lineLimit(1)
            Text(note.text).font(.anuMeta).foregroundStyle(.secondary).lineLimit(2)
            Text(note.updated.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct NoteEditor: View {
    let draft: NoteDraft
    @ObservedObject var model: NotesModel
    let onClose: () -> Void
    @State private var title = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title (optional)", text: $title)
                    .accessibilityIdentifier("noteTitleField")
                TextEditor(text: $text)
                    .frame(minHeight: 200)
                    .accessibilityIdentifier("noteTextField")
                if let problem = model.problem {
                    Text(problem).font(.anuMeta).foregroundStyle(.red)
                }
                if let note = draft.note {
                    Section { NoteShareButton(note: note) }
                }
            }
            .navigationTitle(draft.note == nil ? "New Note" : "Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if model.save(id: draft.note?.id, title: title, text: text) { onClose() }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("saveNoteButton")
                }
            }
            .onAppear {
                title = draft.note?.title ?? ""
                text = draft.note?.text ?? ""
                model.problem = nil
            }
        }
    }
}

/// "Share to Notes…": the system share sheet with the note's text, so it can
/// go to Apple Notes (or anywhere). Nothing is sent until the user picks an
/// app there; a finished share is recorded in the privacy ledger.
struct NoteShareButton: View {
    let note: Note
    @State private var sharing = false

    var body: some View {
        #if canImport(UIKit)
        Button { sharing = true } label: { Label("Share to Notes…", systemImage: "square.and.arrow.up") }
            .accessibilityIdentifier("shareNoteButton")
            .sheet(isPresented: $sharing) {
                ActivityShareSheet(text: NoteStore.shareText(note)) { activity in
                    NotesModel.recordShare(note, to: activity)
                }
                .presentationDetents([.medium, .large])
            }
        #else
        ShareLink(item: NoteStore.shareText(note)) { Label("Share to Notes…", systemImage: "square.and.arrow.up") }
        #endif
    }
}

#if canImport(UIKit)
/// UIKit's share sheet, which (unlike `ShareLink`) says whether something was
/// shared and with which app.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let text: String
    let onShared: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        controller.completionWithItemsHandler = { activity, completed, _, _ in
            guard completed else { return }
            let name = activity?.rawValue ?? "another app"
            Task { @MainActor in onShared(name) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
