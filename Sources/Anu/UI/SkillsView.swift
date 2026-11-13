import SwiftUI
import UniformTypeIdentifiers

/// Settings → Skills (ADR-120): every skill with its switch, its details, and
/// Add from file, Add from URL and Delete for the ones the user added.
struct SkillsView: View {
    var library: SkillLibrary = .shared

    @State private var entries: [SkillEntry] = []
    @State private var problems: [String] = []
    @State private var importing = false
    @State private var askingURL = false
    @State private var address = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Form {
            let builtIn = entries.filter { $0.skill.origin == .builtIn }
            let added = entries.filter { $0.skill.origin == .added }

            Section {
                ForEach(builtIn) { row($0) }
            } header: {
                Text("Built in")
            } footer: {
                Text("Anu lists each turned-on skill to the model by name and description, and loads a skill's instructions only when a request needs it. Scripts run on this device with no network.")
            }

            Section {
                ForEach(added) { row($0) }
                    .onDelete { offsets in
                        for index in offsets { delete(added[index].skill.name) }
                    }
                Button {
                    importing = true
                } label: {
                    Label("Add from File", systemImage: "doc.badge.plus")
                }
                .accessibilityIdentifier("skillAddFile")
                Button {
                    address = ""
                    askingURL = true
                } label: {
                    Label("Add from URL", systemImage: "link.badge.plus")
                }
                .accessibilityIdentifier("skillAddURL")
                if busy { ProgressView() }
            } header: {
                Text("Added by you")
            } footer: {
                Text("A skill you add is someone else's words. After Anu reads one, or runs any skill's script, anything else that request does outside Anu waits for your approval. A skill from a web address is downloaded once, written to the Privacy Ledger, and runs from the saved copy.")
            }

            if !problems.isEmpty {
                Section("Not loaded") {
                    ForEach(problems, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("Skills")
        .onAppear(perform: refresh)
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.folder, .plainText, UTType(filenameExtension: "md") ?? .plainText],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                perform { try library.addFromFile(url) }
            case .failure(let error):
                message = error.localizedDescription
            }
        }
        .alert("Add a skill from a web address", isPresented: $askingURL) {
            TextField("https://example.com/skills/my-skill", text: $address)
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            Button("Add") {
                let typed = address
                busy = true
                Task {
                    do {
                        let skill = try await library.addFromURL(typed)
                        message = "Added \(skill.name)."
                    } catch {
                        message = "Couldn't add that skill: \(error.localizedDescription)"
                    }
                    busy = false
                    refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The address of a skill folder, or of its SKILL.md. Anu reads SKILL.md and the scripts it names, once.")
        }
        .alert("Skills", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private func row(_ entry: SkillEntry) -> some View {
        HStack {
            NavigationLink {
                SkillDetailView(skill: entry.skill, enabled: binding(entry), onDelete: { delete(entry.skill.name) })
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.skill.name)
                    Text(entry.skill.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Toggle(entry.skill.name, isOn: binding(entry))
                .labelsHidden()
                .accessibilityIdentifier("skillToggle_\(entry.skill.name)")
        }
    }

    private func binding(_ entry: SkillEntry) -> Binding<Bool> {
        Binding(
            get: { library.entries().first { $0.skill.name == entry.skill.name }?.enabled ?? entry.enabled },
            set: { on in library.setEnabled(entry.skill.name, on); refresh() })
    }

    private func perform(_ action: () throws -> AgentSkill) {
        do {
            let skill = try action()
            message = "Added \(skill.name)."
        } catch {
            message = "Couldn't add that skill: \(error.localizedDescription)"
        }
        refresh()
    }

    private func delete(_ name: String) {
        do { try library.delete(name) } catch { message = error.localizedDescription }
        refresh()
    }

    private func refresh() {
        entries = library.entries()
        problems = library.problems
    }
}

/// One skill: where it came from, and its whole SKILL.md.
struct SkillDetailView: View {
    let skill: AgentSkill
    @Binding var enabled: Bool
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Toggle("Turned On", isOn: $enabled)
                LabeledContent("Name", value: skill.name)
                LabeledContent("From", value: skill.origin == .builtIn ? "Built into Anu" : (skill.source ?? "A file you added"))
                if skill.requireSecret {
                    Text("Needs an API key. Anu doesn't give keys to skills, so its script won't run.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let homepage = skill.homepage, let url = URL(string: homepage), url.scheme == "https" {
                    Link("Homepage", destination: url)
                }
            } footer: {
                Text(skill.description)
            }
            Section("Instructions") {
                Text(skill.instructions)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            if skill.origin == .added {
                Section {
                    Button("Delete Skill", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                    .accessibilityIdentifier("skillDelete")
                }
            }
        }
        .navigationTitle(skill.name)
    }
}
