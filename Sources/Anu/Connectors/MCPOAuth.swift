import Foundation

#if canImport(MCP)
// Bridges the SDK's OAuth 2.1 flow to iOS: presents the authorization URL in a
// secure browser sheet (ASWebAuthenticationSession) and persists tokens in the
// Keychain. Kept behind the MCP import guard like the rest of the SDK surface.
@_implementationOnly import MCP
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#endif

enum MCPOAuthError: Error, LocalizedError {
    case cancelled
    case cannotStartSession

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in was cancelled."
        case .cannotStartSession: return "Couldn't open the sign-in browser."
        }
    }
}

/// Keychain-backed `TokenStorage` — wraps the MCP-free `JSONKeychainBox` so the
/// SDK's acquired tokens (incl. refresh token + DCR-assigned client id) survive
/// app restarts. One per server (`mcp_oauth_<serverID>`).
final class KeychainTokenStorage: TokenStorage, @unchecked Sendable {
    private let box: JSONKeychainBox<OAuthAccessToken>
    init(serverID: UUID) { self.box = JSONKeychainBox(key: MCPOAuthToken.key(for: serverID)) }
    func save(_ token: OAuthAccessToken) { box.save(token) }
    func load() -> OAuthAccessToken? { box.load() }
    func clear() { box.clear() }
}

/// Presents the OAuth authorization URL via `ASWebAuthenticationSession` and
/// returns the redirect URL carrying the authorization code. The SDK drives
/// discovery, dynamic client registration, PKCE, token exchange and refresh.
final class WebAuthSessionDelegate: NSObject, OAuthAuthorizationDelegate, @unchecked Sendable {
    private let callbackScheme: String
    private var session: ASWebAuthenticationSession?  // strong ref for the flow's lifetime

    init(callbackScheme: String) {
        self.callbackScheme = callbackScheme
        super.init()
    }

    func presentAuthorizationURL(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let session = ASWebAuthenticationSession(
                    url: url, callbackURLScheme: callbackScheme
                ) { callbackURL, error in
                    if let callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: MCPOAuthError.cancelled)
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false  // reuse existing SSO
                self.session = session
                if !session.start() {
                    continuation.resume(throwing: MCPOAuthError.cannotStartSession)
                }
            }
        }
    }
}

extension WebAuthSessionDelegate: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        return keyWindow ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}

/// Builds a per-server OAuth authorizer for the HTTPClientTransport. Uses an
/// empty client id as the dynamic-registration placeholder (the SDK registers
/// the client via RFC 7591 and fills it in); redirect uses our custom scheme,
/// which `ASWebAuthenticationSession` self-registers (no Info.plist needed).
func makeOAuthAuthorizer(serverID: UUID, callbackScheme: String = "anu") -> any HTTPClientAuthorizer {
    let config = OAuthConfiguration(
        grantType: .authorizationCode,
        authentication: .none(clientID: ""),
        authorizationRedirectURI: URL(string: "\(callbackScheme)://oauth-callback"),
        clientName: "Anu",
        authorizationDelegate: WebAuthSessionDelegate(callbackScheme: callbackScheme)
    )
    return OAuthAuthorizer(configuration: config, tokenStorage: KeychainTokenStorage(serverID: serverID))
}
#endif
