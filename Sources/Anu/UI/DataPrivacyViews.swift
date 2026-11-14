import SwiftUI

/// Settings → Where Your Data Goes: every place anything can leave this
/// device, what is sent, and when (App Store Review Guideline 5.1.2(i):
/// clear disclosure of data shared with third parties, including third-party
/// AI). Nothing here turns anything on; each destination is off until the
/// user sets it up, and the Privacy Ledger logs every send.
struct DataDestinationsView: View {
    struct Destination: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
    }

    static let onDevice = Destination(
        id: "device", symbol: "iphone", title: "This device",
        detail: "Chats, memory, the vault, voice notes, skills, workflows and the ledger are stored only here, encrypted. Gemma, speech recognition (when your language supports on-device recognition) and Apple's on-device model run here. Nothing is sent to the developer of Anu, and there are no ads, analytics or tracking.")

    static let destinations: [Destination] = [
        Destination(
            id: "gemini", symbol: "sparkles", title: "Google Gemini (optional)",
            detail: "Only after you add your own Gemini API key. When a request is handed to the cloud helper, the text of that request and the recent conversation it needs are sent to Google, with names, numbers, addresses and other personal details removed first. Google's Gemini API terms apply to what Google keeps."),
        Destination(
            id: "private", symbol: "lock.shield", title: "Your private compute server (optional)",
            detail: "Only if you configure one. The same redacted request goes to the server address you entered, which you or your organisation operate."),
        Destination(
            id: "mac", symbol: "desktopcomputer", title: "Your Mac (optional)",
            detail: "Only after you pair it in Settings → Your Mac. Requests you hand to your Mac go over your local network to the model running there."),
        Destination(
            id: "connectors", symbol: "app.connected.to.app.below.fill", title: "MCP servers, REST APIs and agents you add (optional)",
            detail: "Only servers you add yourself. When Anu uses one of their tools, the tool's inputs (for example a search term or a page to fetch) go to that server, and anything that acts on your behalf waits for your approval of the exact content."),
        Destination(
            id: "gmail", symbol: "envelope", title: "Gmail (optional)",
            detail: "Only after you sign in with Google. Anu reads and sends mail through Google's Gmail API when you ask, and every send waits for your approval."),
        Destination(
            id: "search", symbol: "magnifyingglass", title: "Brave Search (optional)",
            detail: "Only after you add a Brave Search key. Web search queries go to Brave."),
        Destination(
            id: "models", symbol: "arrow.down.circle", title: "Model downloads",
            detail: "Gemma model files are downloaded from Hugging Face. Nothing about you is sent with the download."),
    ]

    var body: some View {
        List {
            Section {
                row(Self.onDevice)
            } footer: {
                Text("Every request starts on this device and stays here unless it needs one of the services below.")
            }
            Section {
                ForEach(Self.destinations) { row($0) }
            } header: {
                Text("Only if you turn it on")
            } footer: {
                Text("The Privacy Ledger shows every send, with the exact text and what was removed. You can delete everything Anu stores in Settings → Delete All My Data.")
            }
            Section {
                NavigationLink {
                    PrivacyView()
                } label: {
                    Label("Privacy Ledger", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .navigationTitle("Where Your Data Goes")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("dataDestinationsView")
    }

    private func row(_ d: Destination) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(d.title).font(.body.weight(.semibold))
                Text(d.detail).font(.callout).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: d.symbol)
        }
        .padding(.vertical, 2)
    }
}

/// Settings → Delete All My Data: a destructive button behind a
/// confirmation, then a screen that asks the user to close Anu so anything
/// still in memory is gone too (the erase runs once more at next launch).
struct DeleteAllDataSection: View {
    @State private var confirming = false
    @State private var erasing = false
    @State private var finished = false

    var body: some View {
        Section {
            Button(role: .destructive) {
                confirming = true
            } label: {
                HStack {
                    Label("Delete All My Data", systemImage: "trash")
                    if erasing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(erasing)
            .accessibilityIdentifier("deleteAllDataButton")
            .confirmationDialog("Delete everything Anu stores?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Delete All My Data", role: .destructive) {
                    erasing = true
                    Task {
                        await DataEraser.eraseEverything()
                        erasing = false
                        finished = true
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Chats, memory, the vault and saved keys, sign-ins, voice notes, skills, workflows, notes, the privacy ledger, activity and settings are deleted from this device. This can't be undone. The downloaded model is kept.")
            }
        } footer: {
            Text("Removes everything Anu has stored on this device. Data already sent to a service you set up (such as Google Gemini) is kept by that service under its own terms.")
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $finished) { ErasedView() }
        #else
        .sheet(isPresented: $finished) { ErasedView() }
        #endif
    }
}

/// Shown after the erase; it can't be dismissed, so nothing new is written
/// in a session that may still hold old data in memory.
private struct ErasedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Your data is deleted")
                .font(.title2.weight(.semibold))
            Text(closeHint)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .interactiveDismissDisabled()
        .accessibilityIdentifier("dataErasedView")
    }

    private var closeHint: String {
        #if os(iOS)
        "Close Anu (swipe it away in the app switcher) and open it again to finish. Anu starts fresh, with the downloaded model still in place."
        #else
        "Quit Anu (⌘Q) and open it again to finish. Anu starts fresh, with the downloaded model still in place."
        #endif
    }
}
