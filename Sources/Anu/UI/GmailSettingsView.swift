import SwiftUI

/// Settings → Connectors → Gmail: the user's OAuth client ID, Sign in, the
/// signed-in account, Sign out (Android parity #10). Tokens never pass
/// through this screen; they go from Google straight into the vault.
@MainActor
final class GmailConnectionModel: ObservableObject {
    @Published var clientID: String = GmailSettings.clientID
    @Published private(set) var account: GmailAccount?
    @Published private(set) var busy = false
    @Published var problem: String?

    private let session: GmailSession

    init(session: GmailSession = .shared) {
        self.session = session
    }

    var isSignedIn: Bool { account != nil }

    func load() async {
        account = await session.isSignedIn ? await session.account : nil
    }

    func signIn() async {
        GmailSettings.clientID = clientID
        problem = nil
        busy = true
        defer { busy = false }
        #if canImport(AuthenticationServices)
        do {
            account = try await session.signIn(clientID: clientID, presenter: SystemWebAuthPresenter())
        } catch GmailAuthError.cancelled {
            // The user closed the sheet; nothing to report.
        } catch {
            problem = error.localizedDescription
        }
        #else
        problem = GmailAuthError.cannotStart.localizedDescription
        #endif
    }

    func signOut() async {
        busy = true
        defer { busy = false }
        await session.signOut()
        account = nil
    }
}

struct GmailSettingsView: View {
    @StateObject private var model = GmailConnectionModel()

    var body: some View {
        Form {
            Section {
                TextField("1234-abc.apps.googleusercontent.com", text: $model.clientID)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .disabled(model.isSignedIn)
                    .accessibilityIdentifier("gmailClientID")
            } header: {
                Text("OAuth client ID")
            } footer: {
                Text("Create an iOS OAuth client in your own Google Cloud project and paste its client ID here. There is no client secret. See Docs/GMAIL_SETUP.md.")
            }

            Section {
                if let account = model.account {
                    LabeledContent("Signed in as", value: account.email ?? "Your Google account")
                    Button("Sign out", role: .destructive) { Task { await model.signOut() } }
                        .disabled(model.busy)
                        .accessibilityIdentifier("gmailSignOut")
                } else {
                    Button {
                        Task { await model.signIn() }
                    } label: {
                        if model.busy { ProgressView() } else { Text("Sign in with Google") }
                    }
                    .disabled(model.busy || model.clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("gmailSignIn")
                }
                if let problem = model.problem {
                    Text(problem).foregroundStyle(.red).font(.footnote)
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Anu can search and read your mail, save drafts, and send — sending always shows you the exact recipients, subject and body first. Email is treated as untrusted. Tokens are kept in the Vault and sent only to Google; every request is in the Privacy Ledger. Signing out deletes them.")
            }
        }
        .navigationTitle("Gmail")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.load() }
    }
}
