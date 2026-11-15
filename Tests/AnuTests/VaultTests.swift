import XCTest
@testable import Anu

/// The vault's rules (Android parity §11, P3/I1): values leave only as a header
/// on HTTPS to a bound host from an allowed caller; every use is audited; a
/// tampered binding is refused; metadata never carries the value.
final class VaultTests: XCTestCase {
    private var backend: InMemoryVaultBackend!
    private var vault: Vault!

    override func setUp() {
        super.setUp()
        backend = InMemoryVaultBackend()
        vault = Vault(backend: backend)
    }

    private func request(_ url: String) -> URLRequest { URLRequest(url: URL(string: url)!) }
    private let geminiUse = SecretUse(ref: .gemini, header: "x-goog-api-key", caller: VaultCaller.gemini)

    func testAttachesHeaderForBoundHostAndCaller() throws {
        try KnownSecret.gemini.store("AIza-secret", in: vault)
        let out = try vault.authorize(request("https://generativelanguage.googleapis.com/v1beta/x"), use: geminiUse)
        XCTAssertEqual(out.value(forHTTPHeaderField: "x-goog-api-key"), "AIza-secret")
        XCTAssertNotNil(vault.item(.gemini)?.lastUsedAt)
        XCTAssertEqual(vault.activity.first?.outcome, .sent)
        XCTAssertEqual(vault.activity.first?.host, "generativelanguage.googleapis.com")
    }

    func testSchemePrefixesValue() throws {
        try vault.store("tok", ref: SecretRef("svc"), kind: .oauthToken, label: "Svc", service: "Svc",
                        boundHosts: ["api.svc.test"], allowedUsers: [VaultCaller.connectors])
        let out = try vault.authorize(request("https://api.svc.test/a"),
                                      use: SecretUse(ref: SecretRef("svc"), header: "Authorization",
                                                     caller: VaultCaller.connectors, scheme: "Bearer"))
        XCTAssertEqual(out.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testRefusesOtherHost() throws {
        try KnownSecret.gemini.store("AIza-secret", in: vault)
        XCTAssertThrowsError(try vault.authorize(request("https://evil.example.com/x"), use: geminiUse)) {
            XCTAssertEqual($0 as? VaultError, .hostNotBound("evil.example.com"))
        }
        XCTAssertEqual(vault.activity.first?.outcome, .refused)
        XCTAssertNil(vault.item(.gemini)?.lastUsedAt)
    }

    func testRefusesLookalikeSubdomain() throws {
        try KnownSecret.gemini.store("AIza-secret", in: vault)
        XCTAssertThrowsError(try vault.authorize(
            request("https://generativelanguage.googleapis.com.evil.test/x"), use: geminiUse))
    }

    func testRefusesPlainHTTP() throws {
        try KnownSecret.gemini.store("AIza-secret", in: vault)
        XCTAssertThrowsError(try vault.authorize(request("http://generativelanguage.googleapis.com/x"), use: geminiUse)) {
            XCTAssertEqual($0 as? VaultError, .insecureScheme)
        }
    }

    func testRefusesCallerNotAllowed() throws {
        try KnownSecret.gemini.store("AIza-secret", in: vault)
        let use = SecretUse(ref: .gemini, header: "x-goog-api-key", caller: VaultCaller.webSearch)
        XCTAssertThrowsError(try vault.authorize(request("https://generativelanguage.googleapis.com/x"), use: use)) {
            XCTAssertEqual($0 as? VaultError, .callerNotAllowed(VaultCaller.webSearch))
        }
    }

    func testMissingItemThrowsNotFound() {
        XCTAssertThrowsError(try vault.authorize(request("https://generativelanguage.googleapis.com/x"), use: geminiUse)) {
            XCTAssertEqual($0 as? VaultError, .notFound("gemini_api_key"))
        }
    }

    func testTamperedBindingIsRefused() throws {
        try KnownSecret.gemini.store("AIza-secret", in: vault)
        // Point the stored value's binding at another host, as editing the item
        // outside Anu would; the metadata no longer matches, so use is refused.
        let raw = try XCTUnwrap(backend.raw("item.gemini_api_key"))
        let tampered = String(decoding: raw, as: UTF8.self)
            .replacingOccurrences(of: "generativelanguage.googleapis.com", with: "evil.test")
        try backend.write(Data(tampered.utf8), account: "item.gemini_api_key", protection: .deviceUnlocked)
        XCTAssertThrowsError(try vault.authorize(request("https://generativelanguage.googleapis.com/x"), use: geminiUse)) {
            XCTAssertEqual($0 as? VaultError, .bindingMismatch)
        }
    }

    func testPresenceItemLockedWhenUserCancels() throws {
        try vault.store("pw", ref: SecretRef("mail"), kind: .appPassword, label: "Mail", service: "Mail",
                        boundHosts: ["imap.mail.test"], allowedUsers: [VaultCaller.connectors], protection: .userPresence)
        backend.lockedAccounts = ["item.mail"]
        XCTAssertThrowsError(try vault.authorize(request("https://imap.mail.test/"),
                                                 use: SecretUse(ref: SecretRef("mail"), header: "X-Pw", caller: VaultCaller.connectors))) {
            XCTAssertEqual($0 as? VaultError, .locked)
        }
    }

    func testPasswordsMustUsePresence() {
        XCTAssertThrowsError(try vault.store("pw", ref: SecretRef("p"), kind: .password, label: "P", service: "P",
                                             boundHosts: [], allowedUsers: [], protection: .deviceUnlocked)) {
            XCTAssertEqual($0 as? VaultError, .protectionNotAllowed)
        }
    }

    func testMetadataNeverContainsValue() throws {
        try KnownSecret.gemini.store("AIza-very-secret", in: vault)
        let item = try XCTUnwrap(vault.item(.gemini))
        let encoded = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
        XCTAssertFalse(encoded.contains("AIza-very-secret"))
        XCTAssertFalse("\(item)".contains("AIza-very-secret"))
        XCTAssertEqual("\(SecretRef.gemini)", "SecretRef(gemini_api_key)")
        let activity = String(decoding: try JSONEncoder().encode(vault.activity), as: UTF8.self)
        XCTAssertFalse(activity.contains("AIza-very-secret"))
        let index = String(decoding: try XCTUnwrap(backend.raw("vault.index")), as: UTF8.self)
        XCTAssertFalse(index.contains("AIza-very-secret"))
    }

    func testEmptyValueDeletesAndStateSurvivesReload() throws {
        try KnownSecret.braveSearch.store("BSA-1", in: vault)
        try KnownSecret.gemini.store("AIza-1", in: vault)
        let reloaded = Vault(backend: backend)
        XCTAssertEqual(reloaded.items.map(\.id).sorted(), ["gemini_api_key", "search_api_key"])
        try KnownSecret.gemini.store("   ", in: reloaded)
        XCTAssertFalse(reloaded.contains(.gemini))
        XCTAssertEqual(reloaded.activity.first?.outcome, .deleted)
    }

    func testRevealForUser() throws {
        try KnownSecret.gemini.store("AIza-secret", in: vault)
        XCTAssertEqual(try vault.revealForUser(.gemini), "AIza-secret")
        XCTAssertEqual(vault.activity.first?.outcome, .shown)
    }

    func testReplacingKeepsCreatedDate() throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        let timed = Vault(backend: backend, now: { clock })
        try KnownSecret.gemini.store("a", in: timed)
        clock = Date(timeIntervalSince1970: 2_000)
        try KnownSecret.gemini.store("b", in: timed)
        XCTAssertEqual(timed.item(.gemini)?.createdAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(try timed.revealForUser(.gemini), "b")
    }

    func testActivityIsCapped() throws {
        try KnownSecret.gemini.store("AIza", in: vault)
        for _ in 0..<250 {
            _ = try? vault.authorize(request("https://generativelanguage.googleapis.com/x"), use: geminiUse)
        }
        XCTAssertEqual(vault.activity.count, 200)
    }
}

/// Connector tokens move out of saved configs into the vault, bound to their
/// own server's host (Android ADR-046).
final class ConnectorSecretsTests: XCTestCase {
    private let vault = Vault(backend: InMemoryVaultBackend())

    func testMCPBearerTokenIsSealedAndBound() throws {
        let server = MCPServerConfig(name: "Docs", endpoint: "https://mcp.docs.test/mcp", auth: .bearer("tok-1"), enabled: true)
        let sealed = ConnectorSecrets.seal(server, in: vault)
        XCTAssertEqual(sealed.auth, .bearer(""))
        let item = try XCTUnwrap(vault.item(ConnectorSecrets.ref(mcp: server.id)))
        XCTAssertEqual(item.boundHosts, ["mcp.docs.test"])
        XCTAssertEqual(item.allowedUsers, [VaultCaller.connectors])

        let ok = ConnectorSecrets.authorizeMCP(URLRequest(url: URL(string: "https://mcp.docs.test/mcp")!),
                                               serverID: server.id, vault: vault)
        XCTAssertEqual(ok.value(forHTTPHeaderField: "Authorization"), "Bearer tok-1")
        let elsewhere = ConnectorSecrets.authorizeMCP(URLRequest(url: URL(string: "https://other.test/mcp")!),
                                                      serverID: server.id, vault: vault)
        XCTAssertNil(elsewhere.value(forHTTPHeaderField: "Authorization"))
    }

    func testRESTHeaderIsSealedAndAttached() throws {
        let rest = RESTConnectorConfig(name: "Cats", baseURL: "https://api.cats.test/v1",
                                       authHeaderName: "X-Key", authHeaderValue: "k-9")
        let sealed = ConnectorSecrets.seal(rest, in: vault)
        XCTAssertNil(sealed.authHeaderValue)
        XCTAssertEqual(sealed.authHeaderName, "X-Key")
        let out = try ConnectorSecrets.authorizeREST(URLRequest(url: URL(string: "https://api.cats.test/v1/x")!),
                                                     connector: sealed, vault: vault)
        XCTAssertEqual(out.value(forHTTPHeaderField: "X-Key"), "k-9")
        XCTAssertThrowsError(try ConnectorSecrets.authorizeREST(URLRequest(url: URL(string: "https://evil.test/")!),
                                                                connector: sealed, vault: vault))
    }

    func testNothingToSealLeavesConfigAlone() {
        let open = MCPServerConfig(name: "Open", endpoint: "https://open.test", auth: .none, enabled: true)
        XCTAssertEqual(ConnectorSecrets.seal(open, in: vault), open)
        XCTAssertTrue(vault.items.isEmpty)
    }
}
