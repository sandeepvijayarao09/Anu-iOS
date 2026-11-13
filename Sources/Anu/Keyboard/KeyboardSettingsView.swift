import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The status line Settings → Keyboard shows, from what the keyboard last
/// reported (it can only report with Full Access) and whether iOS lists it.
enum KeyboardSetupStatus: Equatable {
    /// Not seen: either not added, or added without Full Access.
    case notSeen
    case seen(lastSeen: Date, appleModel: Bool)

    static func from(_ status: KeyboardStatus?) -> KeyboardSetupStatus {
        guard let status, status.hasFullAccess else { return .notSeen }
        return .seen(lastSeen: status.lastSeen, appleModel: status.appleModelAvailable)
    }

    var title: String {
        switch self {
        case .notSeen: return "Not seen yet"
        case .seen: return "On, with Full Access"
        }
    }

    var detail: String {
        switch self {
        case .notSeen:
            return "iOS doesn't tell apps whether their keyboard is on. Anu Keyboard reports here once it's been used with Full Access. Without Full Access it still types; only this status and the hand-off to the app need it."
        case .seen(let date, let apple):
            let when = date.formatted(.relative(presentation: .named))
            return apple
                ? "Last used \(when). AI runs on Apple's on-device model, in the keyboard."
                : "Last used \(when). Apple's on-device model isn't available, so the AI strip hands text to the Anu app's on-device model."
        }
    }
}

/// Settings → Keyboard: how to turn Anu Keyboard on, its status, and what it
/// can and can't see.
struct KeyboardSettingsView: View {
    @State private var status = KeyboardSetupStatus.from(KeyboardStatusStore().load())

    var body: some View {
        Form {
            #if os(iOS)
            Section {
                LabeledContent("Status", value: status.title)
                Text(status.detail).font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                step(1, "Open Settings → General → Keyboard → Keyboards.")
                step(2, "Tap Add New Keyboard… and choose Anu.")
                step(3, "Optional: tap Anu and turn on Allow Full Access, so the keyboard can hand text to this app when Apple's on-device model isn't available.")
                step(4, "In any app, hold the globe key and pick Anu.")
                Button("Open Anu's Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            } header: {
                Text("Turn it on")
            } footer: {
                Text("iOS lets only you add a keyboard. Anu's page in Settings lists Keyboards once it's installed.")
            }

            Section {
                privacy("keyboard", "Typing goes straight into the field. No dictionary, no suggestions, no history: nothing you type is kept or learned from.")
                privacy("hand.tap", "The AI strip reads the text before the cursor (or your selection) only when you tap an action, and changes the field only when you tap Replace or Insert.")
                privacy("lock", "Password, one-time code and card fields get no AI, and Anu reads nothing in them. iOS gives secure and phone fields to its own keyboard anyway.")
                privacy("iphone", "AI runs on this device only: Apple's on-device model in the keyboard, or Anu's on-device model in this app. The keyboard never sends text to the cloud, and has no tools, so nothing in your text can make anything happen.")
                privacy("tray", "With Full Access, a hand-off waits in Anu's shared App Group container for at most 15 minutes and is deleted once used.")
            } header: {
                Text("Privacy")
            }
            #else
            Section {
                Text("Anu Keyboard and Rewrite with Anu are for iPhone and iPad.")
                    .foregroundStyle(.secondary)
            }
            #endif
        }
        .navigationTitle("Keyboard")
        .onAppear { status = KeyboardSetupStatus.from(KeyboardStatusStore().load()) }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.footnote.weight(.semibold)).frame(width: 18)
            Text(text)
        }
    }

    private func privacy(_ symbol: String, _ text: String) -> some View {
        Label { Text(text).font(.callout) } icon: { Image(systemName: symbol) }
    }
}
