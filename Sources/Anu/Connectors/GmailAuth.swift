import CryptoKit
import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Google sign-in for Gmail (Android parity #10). An installed-app OAuth flow:
// ASWebAuthenticationSession + PKCE + the client's reversed-ID redirect
// scheme. iOS OAuth clients have no secret. Tokens go straight into the vault
// as `.oauthToken` items — the access token bound to gmail.googleapis.com, the
// refresh token to oauth2.googleapis.com — usable only by `VaultCaller.gmail`.
// Requests get the token through `Vault.authorize`; nothing reads it back.

/// The scopes Anu asks for, as Anu Android does (ADR-029): read, draft, send.
enum GmailScopes {
    static let readonly = "https://www.googleapis.com/auth/gmail.readonly"
    static let compose = "https://www.googleapis.com/auth/gmail.compose"
    static let send = "https://www.googleapis.com/auth/gmail.send"
    static let all = [readonly, compose, send]
}

enum GmailHosts {
    static let api = "gmail.googleapis.com"
    static let oauth = "oauth2.googleapis.com"
}

enum GmailAuthError: Error, Equatable, LocalizedError {
    case noClientID
    case invalidClientID
    case notSignedIn
    case cancelled
    case cannotStart
    case stateMismatch
    case denied(String)
    case noCode
    case tokenEndpoint(Int, String)
    case noRefreshToken
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .noClientID: return "Enter your Google OAuth client ID in Settings → Connectors → Gmail first."
        case .invalidClientID: return "That doesn't look like an iOS OAuth client ID (it ends in .apps.googleusercontent.com)."
        case .notSignedIn: return "Gmail isn't connected. Sign in under Settings → Connectors → Gmail."
        case .cancelled: return "Sign-in was cancelled."
        case .cannotStart: return "Couldn't open the Google sign-in sheet."
        case .stateMismatch: return "The sign-in reply didn't match the request, so it was ignored."
        case .denied(let reason): return "Google didn't grant access (\(reason))."
        case .noCode: return "Google's reply had no authorization code."
        case .tokenEndpoint(let status, let message): return "Google's token service said \(status): \(message)"
        case .noRefreshToken: return "Google didn't return a refresh token. Remove Anu's access in your Google account and sign in again."
        case .malformedResponse: return "Google's token reply couldn't be read."
        }
    }
}

// MARK: - PKCE and URLs

/// RFC 7636 proof key: a random verifier and its S256 challenge.
struct PKCE: Equatable, Sendable {
    let verifier: String
    let challenge: String

    init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
    }

    /// 64 characters from the unreserved set (RFC 7636 allows 43–128).
    static func make() -> PKCE {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return PKCE(verifier: String((0..<64).map { _ in alphabet.randomElement(using: &generator)! }))
    }

    static func challenge(for verifier: String) -> String {
        GmailMIME.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

enum GoogleOAuth {
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://\(GmailHosts.oauth)/token")!
    static let revokeEndpoint = URL(string: "https://\(GmailHosts.oauth)/revoke")!

    /// "1234-abc.apps.googleusercontent.com", as Google issues for iOS clients.
    static func isValidClientID(_ id: String) -> Bool {
        id.range(of: #"^[0-9]+-[A-Za-z0-9_]+\.apps\.googleusercontent\.com$"#, options: .regularExpression) != nil
    }

    /// The iOS client's redirect scheme: its ID reversed,
    /// "com.googleusercontent.apps.1234-abc". ASWebAuthenticationSession
    /// catches it itself, so Info.plist needs no URL type.
    static func redirectScheme(clientID: String) -> String {
        let prefix = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps." + prefix
    }

    static func redirectURI(clientID: String) -> String {
        redirectScheme(clientID: clientID) + ":/oauth2redirect"
    }

    static func authorizationURL(clientID: String, scopes: [String], pkce: PKCE, state: String) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI(clientID: clientID)),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // A refresh token every time, even after an earlier grant.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    /// The authorization code from the redirect, after checking `state`.
    static func code(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == expectedState else { throw GmailAuthError.stateMismatch }
        if let error = value("error") { throw GmailAuthError.denied(error) }
        guard let code = value("code"), !code.isEmpty else { throw GmailAuthError.noCode }
        return code
    }

    /// `application/x-www-form-urlencoded` for `pairs`, in order.
    static func formBody(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let text = pairs.map { name, value in
            name + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
        return Data(text.utf8)
    }
}

// MARK: - Account metadata (never tokens)

/// What Anu remembers about the sign-in besides the tokens: which client and
/// account, and when the access token runs out. The email address is personal
/// data, so this is written only through `SecureFile`.
struct GmailAccount: Codable, Equatable, Sendable {
    var clientID: String
    var email: String?
    var scopes: [String]
    var accessExpiresAt: Date
    var signedInAt: Date
}

struct GmailAccountStore: Sendable {
    let fileURL: URL?
    var keys: DataKeyProviding = KeychainDataKey.shared

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("gmail_account.json")
    }

    func load() -> GmailAccount? {
        guard let fileURL, let data = SecureFile.read(fileURL, keys: keys) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(GmailAccount.self, from: data)
    }

    func save(_ account: GmailAccount) {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(account) else { return }
        try? SecureFile.write(data, to: fileURL, keys: keys)
    }

    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// The user's OAuth client ID. Not a secret (iOS clients have none) and not
/// personal data, so it lives in UserDefaults.
enum GmailSettings {
    static let clientIDKey = "gmail_client_id"
    static var clientID: String {
        get { UserDefaults.standard.string(forKey: clientIDKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: clientIDKey) }
    }
}

// MARK: - Presenting the consent page

protocol WebAuthPresenting: Sendable {
    /// Shows `url` and returns the redirect to `callbackScheme`.
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

#if canImport(AuthenticationServices)
/// ASWebAuthenticationSession, sharing Safari's cookies so an existing Google
/// sign-in is reused.
final class SystemWebAuthPresenter: NSObject, WebAuthPresenting, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    private var session: ASWebAuthenticationSession?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                    if let callback {
                        continuation.resume(returning: callback)
                    } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                        continuation.resume(throwing: GmailAuthError.cancelled)
                    } else {
                        continuation.resume(throwing: error ?? GmailAuthError.cancelled)
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                self.session = session
                if !session.start() { continuation.resume(throwing: GmailAuthError.cannotStart) }
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #else
        return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #endif
    }
}
#endif

// MARK: - Session

/// Records one request in the Privacy Ledger. Tests pass their own ledger.
typealias GmailEgressRecorder = @Sendable (EgressDestination, String) async -> Void

enum GmailLedger {
    static let shared: GmailEgressRecorder = { destination, payload in
        await PrivacyLedger.shared.record(destination: destination, payload: payload, redactions: 0)
    }

    /// "POST /token · 312-byte body": what went where, never a secret.
    static func describe(_ request: URLRequest) -> String {
        let url = request.url
        let query = url?.query.map { "?" + $0 } ?? ""
        let body = (request.httpBody?.count).map { " · \($0)-byte body" } ?? ""
        return "\(request.httpMethod ?? "GET") \(url?.path ?? "")\(query)\(body)"
    }
}

/// Signs in, keeps the access token fresh, and attaches it to Gmail requests.
/// An actor, so concurrent tool calls share one refresh.
actor GmailSession {
    static let shared = GmailSession()

    /// Refresh this long before Google's stated expiry.
    static let expiryMargin: TimeInterval = 60

    let vault: Vault
    private let http: URLSession
    private let store: GmailAccountStore
    private let now: @Sendable () -> Date
    private let record: GmailEgressRecorder
    private var refreshing: Task<Void, Error>?
    private(set) var account: GmailAccount?

    init(
        vault: Vault = .shared,
        http: URLSession = URLSession(configuration: .ephemeral),
        store: GmailAccountStore = GmailAccountStore(fileURL: GmailAccountStore.defaultURL),
        now: @escaping @Sendable () -> Date = Date.init,
        record: @escaping GmailEgressRecorder = GmailLedger.shared
    ) {
        self.vault = vault
        self.http = http
        self.store = store
        self.now = now
        self.record = record
        let saved = store.load()
        // Metadata without a token is a sign-in that was removed elsewhere
        // (the Vault screen); forget it.
        if saved != nil, !vault.contains(.gmailRefresh) { store.clear() } else { account = saved }
    }

    var isSignedIn: Bool { account != nil && vault.contains(.gmailRefresh) }

    // MARK: Sign in

    /// The whole interactive flow: consent sheet, code exchange, profile.
    func signIn(clientID rawID: String, presenter: WebAuthPresenting) async throws -> GmailAccount {
        let clientID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw GmailAuthError.noClientID }
        guard GoogleOAuth.isValidClientID(clientID) else { throw GmailAuthError.invalidClientID }
        let pkce = PKCE.make()
        let state = UUID().uuidString
        let url = GoogleOAuth.authorizationURL(clientID: clientID, scopes: GmailScopes.all, pkce: pkce, state: state)
        let callback = try await presenter.authenticate(
            url: url, callbackScheme: GoogleOAuth.redirectScheme(clientID: clientID))
        return try await completeSignIn(callback: callback, clientID: clientID, pkce: pkce, state: state)
    }

    /// Exchanges the code for tokens, stores them in the vault, and reads the
    /// account's address.
    func completeSignIn(callback: URL, clientID: String, pkce: PKCE, state: String) async throws -> GmailAccount {
        let code = try GoogleOAuth.code(from: callback, expectedState: state)
        var request = URLRequest(url: GoogleOAuth.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleOAuth.formBody([
            ("code", code),
            ("client_id", clientID),
            ("redirect_uri", GoogleOAuth.redirectURI(clientID: clientID)),
            ("grant_type", "authorization_code"),
            ("code_verifier", pkce.verifier),
        ])
        let reply = try await tokenCall(request, purpose: "sign-in")
        guard let refresh = reply.refreshToken else { throw GmailAuthError.noRefreshToken }
        try storeTokens(access: reply.accessToken, refresh: refresh)
        var signedIn = GmailAccount(
            clientID: clientID, email: nil,
            scopes: reply.scope?.split(separator: " ").map(String.init) ?? GmailScopes.all,
            accessExpiresAt: now().addingTimeInterval(reply.expiresIn), signedInAt: now())
        account = signedIn
        store.save(signedIn)
        signedIn.email = try? await GmailClient(session: self, http: http, record: record).profileEmail()
        account = signedIn
        store.save(signedIn)
        return signedIn
    }

    // MARK: Using the token

    /// `request` with the access token attached by the vault, refreshing it
    /// first when it has expired (or `forceRefresh`, after a 401).
    func authorize(_ request: URLRequest, forceRefresh: Bool = false) async throws -> URLRequest {
        guard let current = account, vault.contains(.gmailRefresh) else { throw GmailAuthError.notSignedIn }
        if forceRefresh || !vault.contains(.gmailAccess)
            || current.accessExpiresAt.addingTimeInterval(-Self.expiryMargin) <= now() {
            try await refresh()
        }
        return try vault.authorize(request, use: SecretUse(
            ref: .gmailAccess, header: "Authorization", caller: VaultCaller.gmail, scheme: "Bearer"))
    }

    /// Gets a new access token with the refresh token. Concurrent callers
    /// share one request.
    func refresh() async throws {
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.performRefresh() }
        refreshing = task
        defer { refreshing = nil }
        try await task.value
    }

    private func performRefresh() async throws {
        guard let current = account else { throw GmailAuthError.notSignedIn }
        var request = URLRequest(url: GoogleOAuth.tokenEndpoint)
        request.httpMethod = "POST"
        request.httpBody = GoogleOAuth.formBody([("client_id", current.clientID), ("grant_type", "refresh_token")])
        request = try vault.authorizeFormField(request, ref: .gmailRefresh, field: "refresh_token", caller: VaultCaller.gmail)
        let reply: TokenReply
        do {
            reply = try await tokenCall(request, purpose: "token refresh")
        } catch GmailAuthError.tokenEndpoint(let status, let message) where status == 400 && message.contains("invalid_grant") {
            // Revoked or expired grant: the stored tokens are useless now.
            forget()
            throw GmailAuthError.notSignedIn
        }
        try storeTokens(access: reply.accessToken, refresh: reply.refreshToken)
        var updated = current
        updated.accessExpiresAt = now().addingTimeInterval(reply.expiresIn)
        account = updated
        store.save(updated)
    }

    // MARK: Sign out

    /// Revokes the grant (best effort) and deletes the vault items and the
    /// account file.
    func signOut() async {
        if vault.contains(.gmailRefresh) {
            var request = URLRequest(url: GoogleOAuth.revokeEndpoint)
            request.httpMethod = "POST"
            if let authorized = try? vault.authorizeFormField(
                request, ref: .gmailRefresh, field: "token", caller: VaultCaller.gmail) {
                await record(.restHost(name: "Google sign-in", host: GmailHosts.oauth), GmailLedger.describe(authorized) + " · sign out")
                _ = try? await http.data(for: authorized, delegate: VaultNoRedirects.shared)
            }
        }
        forget()
    }

    private func forget() {
        vault.delete(.gmailAccess)
        vault.delete(.gmailRefresh)
        store.clear()
        account = nil
    }

    // MARK: Private

    private struct TokenReply {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval
        let scope: String?
    }

    private func tokenCall(_ request: URLRequest, purpose: String) async throws -> TokenReply {
        await record(.restHost(name: "Google sign-in", host: GmailHosts.oauth), GmailLedger.describe(request) + " · \(purpose)")
        let (data, response) = try await http.data(for: request, delegate: VaultNoRedirects.shared)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = (json?["error"] as? String).map { error in
                [error, json?["error_description"] as? String].compactMap { $0 }.joined(separator: ": ")
            } ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw GmailAuthError.tokenEndpoint(status, message)
        }
        guard let json, let access = json["access_token"] as? String, !access.isEmpty else {
            throw GmailAuthError.malformedResponse
        }
        let expires = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return TokenReply(accessToken: access, refreshToken: json["refresh_token"] as? String,
                          expiresIn: expires, scope: json["scope"] as? String)
    }

    private func storeTokens(access: String, refresh: String?) throws {
        try vault.store(access, ref: .gmailAccess, kind: .oauthToken, label: "Gmail access token",
                        service: "Gmail", boundHosts: [GmailHosts.api], allowedUsers: [VaultCaller.gmail])
        if let refresh, !refresh.isEmpty {
            try vault.store(refresh, ref: .gmailRefresh, kind: .oauthToken, label: "Gmail refresh token",
                            service: "Gmail", boundHosts: [GmailHosts.oauth], allowedUsers: [VaultCaller.gmail])
        }
    }
}
