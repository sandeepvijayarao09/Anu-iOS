import LocalAuthentication
import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Vault (Settings → Privacy & Transparency → Vault)

/// Lists the secrets Anu holds, where each may be sent and when it was last
/// used, plus the vault's activity. Values are shown only after Face ID /
/// passcode, and only while the item's sheet is open (Android ADR-135).
struct VaultView: View {
    @ObservedObject var vault: Vault = .shared
    @State private var selected: VaultItem?

    var body: some View {
        List {
            Section {
                if vault.items.isEmpty {
                    Text("Nothing in the vault yet. Keys you add in Settings, such as your Gemini key, are kept here and sent only to their own service.")
                        .font(.anuSecondary)
                        .foregroundStyle(.secondary)
                }
                ForEach(vault.items) { item in
                    Button { selected = item } label: {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(item.label).font(.anuBody).foregroundStyle(Color.anuInk)
                            HStack(spacing: Space.tight) {
                                Text(item.destinationSummary)
                                Text(Self.lastUsed(item))
                            }
                            .font(.anuMeta)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("vaultItem_\(item.id)")
                }
            } footer: {
                Text("Models never see these values. Anu attaches a secret only to a secure request for the service it belongs to; anything else is refused and listed below.")
            }

            Section("Vault activity") {
                if vault.activity.isEmpty {
                    Text("No activity yet.").font(.anuSecondary).foregroundStyle(.secondary)
                }
                ForEach(vault.activity.prefix(50)) { entry in
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(Self.describe(entry)).font(.anuBody)
                        HStack(spacing: Space.tight) {
                            if let reason = entry.reason { Text(reason) }
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        }
                        .font(.anuMeta)
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle("Vault")
        .sheet(item: $selected) { item in
            VaultItemSheet(item: item, vault: vault)
        }
        .accessibilityIdentifier("vaultList")
    }

    static func lastUsed(_ item: VaultItem) -> String {
        guard let date = item.lastUsedAt else { return "Not used yet" }
        return "Used " + date.formatted(.relative(presentation: .named))
    }

    static func describe(_ entry: VaultActivity) -> String {
        switch entry.outcome {
        case .sent: return "\(entry.label) sent to \(entry.host ?? "its service") for \(entry.caller)"
        case .refused: return "Refused \(entry.label) for \(entry.caller)" + (entry.host.map { " to \($0)" } ?? "")
        case .shown: return "\(entry.label) shown to you"
        case .added: return "\(entry.label) saved"
        case .deleted: return "\(entry.label) deleted"
        }
    }
}

// MARK: - Item sheet

private struct VaultItemSheet: View {
    let item: VaultItem
    let vault: Vault
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// The value lives only here, only while the sheet is open.
    @State private var revealed: String?
    @State private var message: String?
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Kind", value: item.kind.title)
                    LabeledContent("Service", value: item.service)
                    LabeledContent("Goes to", value: item.boundHosts.isEmpty ? "Nowhere" : item.boundHosts.joined(separator: ", "))
                        .accessibilityIdentifier("vaultItemGoesTo")
                    LabeledContent("Used by", value: item.allowedUsers.map(Self.callerName).joined(separator: ", "))
                    LabeledContent("Unlocks", value: item.protection.title)
                    LabeledContent("Added", value: item.createdAt.formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("Last used", value: VaultView.lastUsed(item))
                }
                Section {
                    if let revealed {
                        Text(revealed)
                            .font(.anuCode)
                            .textSelection(.enabled)
                            .blur(radius: scenePhase == .active ? 0 : 12)
                            .accessibilityIdentifier("vaultRevealedValue")
                        #if os(iOS)
                        Button("Copy (clears in 60 seconds)") { copy(revealed) }
                        #endif
                        Button("Hide") { self.revealed = nil }
                    } else {
                        Button("Show") { Task { await show() } }
                            .accessibilityIdentifier("vaultShowButton")
                    }
                    if let message {
                        Text(message).font(.anuLabel).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Delete", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Deleting it stops \(item.service) from working until you add a new one.")
                }
            }
            .navigationTitle(item.label)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("vaultItemDone") } }
            .confirmationDialog("Delete \(item.label)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { vault.delete(item.ref); dismiss() }
            } message: {
                Text("\(item.service) stops working until you add a new one. This can't be undone.")
            }
            // Leaving the app hides the value (the iOS counterpart of FLAG_SECURE).
            .onChange(of: scenePhase) { _, phase in if phase == .background { revealed = nil } }
            .onDisappear { revealed = nil }
        }
    }

    /// Asks the phone to prove it's the owner first, whatever the item's level.
    private func show() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            message = "Set a passcode on this phone to show saved values."
            return
        }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Show \(item.label)") else { return }
            revealed = try vault.revealForUser(item.ref)
            message = nil
        } catch {
            message = (error as? VaultError)?.errorDescription ?? "Not shown."
        }
    }

    #if os(iOS)
    private func copy(_ value: String) {
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: value]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
        message = "Copied. It's cleared from the clipboard in 60 seconds."
    }
    #endif

    static func callerName(_ caller: String) -> String {
        switch caller {
        case VaultCaller.gemini: return "Gemini"
        case VaultCaller.webSearch: return "Web search"
        case VaultCaller.connectors: return "Services"
        default: return caller
        }
    }
}
