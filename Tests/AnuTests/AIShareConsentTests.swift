import XCTest
@testable import Anu

/// Parity A9 (guideline 5.1.2(i)): nothing goes to a third-party AI before the
/// user agrees on a sheet that names it; the answer is kept and revocable.
@MainActor
final class AIShareConsentTests: XCTestCase {
    private func isolatedStore() -> AIShareConsentStore {
        let name = "consent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return AIShareConsentStore(defaults: defaults)
    }

    /// Fails the test if any request reaches the network.
    private final class NoNetwork: URLProtocol {
        nonisolated(unsafe) static var hits = 0
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            NoNetwork.hits += 1
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
    }

    private func noNetworkSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NoNetwork.self]
        return URLSession(configuration: config)
    }

    func testConsentIsRecordedWithDateAndVersionAndCanBeWithdrawn() {
        let store = isolatedStore()
        XCTAssertFalse(store.isGranted(.gemini))
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        store.grant(.gemini, at: when)
        XCTAssertTrue(store.isGranted(.gemini))
        XCTAssertFalse(store.isGranted(.privateServer), "consent is per provider")
        XCTAssertEqual(store.record(for: .gemini), AIShareConsentRecord(acceptedAt: when, version: AIShareConsentStore.currentVersion))
        store.revoke(.gemini)
        XCTAssertFalse(store.isGranted(.gemini))
    }

    func testTheSheetNamesGeminiAndSaysWhatIsSent() {
        XCTAssertTrue(AIShareProvider.gemini.title.contains("Google Gemini"))
        XCTAssertTrue(AIShareProvider.gemini.operatorLine.contains("Google"))
        XCTAssertTrue(AIShareProvider.whatIsSent.joined().contains("replaced with placeholders"))
    }

    func testGeminiSendsNothingWithoutConsent() async throws {
        let vault = Vault(backend: InMemoryVaultBackend())
        try KnownSecret.gemini.store("AIza-test-key", in: vault)
        NoNetwork.hits = 0
        let before = PrivacyLedger.shared.events.count
        let tool = EscalateToGeminiTool(geminiClient: GeminiClient(session: noNetworkSession(), vault: vault),
                                        consent: FixedAIShareConsentGate(granted: false))
        let result = try await tool.execute(arguments: .object(["task": .string("Plan my week")]))
        XCTAssertEqual(result, AIShareConsentText.notSent(.gemini))
        XCTAssertEqual(NoNetwork.hits, 0, "no Gemini egress before consent")
        XCTAssertEqual(PrivacyLedger.shared.events.count, before)
    }

    func testPrivateServerSendsNothingWithoutConsent() async throws {
        try requireWorkingKeychain()
        let saved = KeychainStore.shared.string(forKey: "pcs_endpoint")
        KeychainStore.shared.set("https://pcs.example.com/api", forKey: "pcs_endpoint")
        defer {
            if let saved { KeychainStore.shared.set(saved, forKey: "pcs_endpoint") }
            else { KeychainStore.shared.remove(forKey: "pcs_endpoint") }
        }
        NoNetwork.hits = 0
        let tool = EscalateToPrivateCloudTool(client: PrivateComputeClient(session: noNetworkSession()),
                                              sessionIdProvider: { "s" },
                                              consent: FixedAIShareConsentGate(granted: false))
        let result = try await tool.execute(arguments: .object(["task": .string("Plan my week")]))
        XCTAssertEqual(result, AIShareConsentText.notSent(.privateServer))
        XCTAssertEqual(NoNetwork.hits, 0)
    }

    func testWithNoSheetOnScreenTheAnswerIsNo() async {
        let store = isolatedStore()
        let center = AIShareConsentCenter()
        let agreed = await center.request(.gemini, store: store)
        XCTAssertFalse(agreed, "a Siri/Shortcuts run can't consent for the user")
        XCTAssertNil(center.pending)
    }

    func testAgreeingOnTheSheetRecordsConsent() async {
        let store = isolatedStore()
        let center = AIShareConsentCenter()
        center.attachPresenter()
        let answer = Task { @MainActor in await center.request(.gemini, store: store) }
        for _ in 0..<200 where center.pending == nil { await Task.yield() }
        XCTAssertEqual(center.pending?.provider, .gemini)
        center.answer(true)
        let agreed = await answer.value
        XCTAssertTrue(agreed)
        XCTAssertTrue(store.isGranted(.gemini))
        XCTAssertNil(center.pending)
    }

    func testDecliningRecordsNothing() async {
        let store = isolatedStore()
        let center = AIShareConsentCenter()
        center.attachPresenter()
        let answer = Task { @MainActor in await center.request(.privateServer, store: store) }
        for _ in 0..<200 where center.pending == nil { await Task.yield() }
        center.answer(false)
        let agreed = await answer.value
        XCTAssertFalse(agreed)
        XCTAssertFalse(store.isGranted(.privateServer))
    }

    func testAStoredAnswerSkipsTheSheet() async {
        let store = isolatedStore()
        store.grant(.gemini)
        let agreed = await SystemAIShareConsentGate(store: store).ensureConsent(.gemini)
        XCTAssertTrue(agreed)
    }
}
