import XCTest
@testable import Anu

// MARK: - Local fakes (kept self-contained so this file owns its test doubles)

private final class LedgerFakeOpener: URLOpening, @unchecked Sendable {
    var opened: [URL] = []
    func open(_ url: URL) async -> Bool { opened.append(url); return true }
}

private final class LedgerFakeInvoker: MCPToolInvoking, @unchecked Sendable {
    func callTool(rawName: String, arguments: JSONValue) async throws -> String { "ok" }
}

/// Returns 200 + a tiny body for any request — used so `GeminiClient.generate`
/// returns without touching the network. The ledger record happens before the
/// call, so the response shape doesn't matter.
private final class LedgerURLStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url ?? URL(string: "https://x")!
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class PrivacyLedgerTests: XCTestCase {

    override func setUpWithError() throws {
        // Instrumentation tests share the singleton; start each from empty.
        PrivacyLedger.shared.clear()
    }

    override func tearDownWithError() throws {
        PrivacyLedger.shared.clear()
    }

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LedgerURLStub.self]
        return URLSession(configuration: config)
    }

    // MARK: - Store logic (isolated, non-persisting instance)

    func testBeginTurnIncrements() {
        let ledger = PrivacyLedger(persists: false)
        XCTAssertEqual(ledger.beginTurn(), 1)
        XCTAssertEqual(ledger.beginTurn(), 2)
    }

    func testRecordComputesByteCountAndClips() {
        let ledger = PrivacyLedger(persists: false)
        ledger.beginTurn()
        let long = String(repeating: "x", count: 1000)
        ledger.record(destination: .cloud(model: "m"), payload: long, redactions: 2)
        let event = try! XCTUnwrap(ledger.events.first)
        XCTAssertEqual(event.byteCount, 1000)            // full size recorded
        XCTAssertTrue(event.payloadSummary.count < 1000) // preview is clipped
        XCTAssertEqual(event.redactions, 2)
    }

    func testLastTurnSummaryZeroEgressWhenNothingLeft() {
        let ledger = PrivacyLedger(persists: false)
        ledger.beginTurn()
        let summary = try! XCTUnwrap(ledger.lastTurnSummary)
        XCTAssertTrue(summary.nothingLeftDevice)
        XCTAssertEqual(summary.byteCount, 0)
    }

    func testCloudEgressCountsAsOffDevice() {
        let ledger = PrivacyLedger(persists: false)
        ledger.beginTurn()
        ledger.record(destination: .cloud(model: "gemini"), payload: "hello", redactions: 3)
        let summary = try! XCTUnwrap(ledger.lastTurnSummary)
        XCTAssertFalse(summary.nothingLeftDevice)
        XCTAssertEqual(summary.offDeviceEvents, 1)
        XCTAssertEqual(summary.redactions, 3)
        XCTAssertEqual(summary.byteCount, 5)
    }

    func testAppLaunchIsOnDeviceAndExcludedFromBytes() {
        let ledger = PrivacyLedger(persists: false)
        ledger.beginTurn()
        ledger.record(destination: .appLaunch(scheme: "maps", target: "maps://?q=x"),
                      payload: "maps://?q=x", redactions: 0)
        let summary = try! XCTUnwrap(ledger.lastTurnSummary)
        XCTAssertTrue(summary.nothingLeftDevice)        // on-device hand-off
        XCTAssertEqual(summary.onDeviceEvents, 1)
        XCTAssertEqual(summary.offDeviceEvents, 0)
        XCTAssertEqual(summary.byteCount, 0)
    }

    func testEventsAttributedToCurrentTurn() {
        let ledger = PrivacyLedger(persists: false)
        ledger.beginTurn()
        ledger.record(destination: .cloud(model: "m"), payload: "a", redactions: 0)
        ledger.beginTurn()
        ledger.record(destination: .cloud(model: "m"), payload: "b", redactions: 0)
        XCTAssertEqual(ledger.eventsForCurrentTurn.count, 1)
        XCTAssertEqual(ledger.eventsForCurrentTurn.first?.payloadSummary, "b")
    }

    func testCapAtMaxEvents() {
        let ledger = PrivacyLedger(persists: false)
        ledger.beginTurn()
        for i in 0..<(PrivacyLedger.maxEvents + 50) {
            ledger.record(destination: .restHost(name: "n", host: "h"), payload: "\(i)", redactions: 0)
        }
        XCTAssertEqual(ledger.events.count, PrivacyLedger.maxEvents)
        // Oldest dropped; the most recent survives.
        XCTAssertEqual(ledger.events.last?.payloadSummary, "\(PrivacyLedger.maxEvents + 49)")
    }

    func testSessionTotals() {
        let ledger = PrivacyLedger(persists: false)
        ledger.beginTurn()
        ledger.record(destination: .cloud(model: "m"), payload: "1234", redactions: 1)        // off, 4B
        ledger.record(destination: .appLaunch(scheme: "tel", target: "t"), payload: "tel", redactions: 0) // on
        let totals = ledger.sessionTotals
        XCTAssertEqual(totals.events, 2)
        XCTAssertEqual(totals.offDevice, 1)
        XCTAssertEqual(totals.redactions, 1)
        XCTAssertEqual(totals.bytes, 4)
    }

    func testClearEmptiesEvents() {
        let ledger = PrivacyLedger(persists: false)
        ledger.beginTurn()
        ledger.record(destination: .cloud(model: "m"), payload: "x", redactions: 0)
        ledger.clear()
        XCTAssertTrue(ledger.events.isEmpty)
    }

    // MARK: - Persistence (PrivacyLedgerStore with a temp directory)

    func testStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PrivacyLedgerStore(directory: dir)
        let event = PrivacyEvent(turn: 1, destination: .mcpServer(name: "deepwiki", host: "mcp.deepwiki.com"),
                                 payloadSummary: "ping {}", redactions: 0, byteCount: 7)
        store.save([event])

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.destination, .mcpServer(name: "deepwiki", host: "mcp.deepwiki.com"))
        store.clear()
        XCTAssertNil(store.load())
    }

    // MARK: - Instrumentation (each egress site records via PrivacyLedger.shared)

    func testRESTToolRecordsEgress() async throws {
        PrivacyLedger.shared.beginTurn()
        let tool = RESTConnectorTool(
            config: RESTConnectorConfig(name: "Demo", baseURL: "https://api.example.com", method: "GET"),
            session: stubbedSession()
        )
        _ = try await tool.execute(arguments: .object(["path": .string("/items")]))
        let event = try XCTUnwrap(PrivacyLedger.shared.events.last)
        XCTAssertEqual(event.destination, .restHost(name: "Demo", host: "api.example.com"))
        XCTAssertTrue(event.destination.leavesDevice)
        XCTAssertTrue(event.payloadSummary.contains("/items"), event.payloadSummary)
    }

    func testAppLauncherRecordsOnDeviceEgress() async throws {
        PrivacyLedger.shared.beginTurn()
        let tool = OpenAppTool(
            appConfig: AppLauncherConfig(enabled: true, allowedSchemes: ["maps"]),
            opener: LedgerFakeOpener()
        )
        _ = try await tool.execute(arguments: .object(["url": .string("maps://?q=coffee")]))
        let event = try XCTUnwrap(PrivacyLedger.shared.events.last)
        XCTAssertEqual(event.destination, .appLaunch(scheme: "maps", target: "maps://?q=coffee"))
        XCTAssertFalse(event.destination.leavesDevice)
    }

    func testMCPProxyRecordsEgress() async throws {
        PrivacyLedger.shared.beginTurn()
        let proxy = MCPToolProxy(
            serverSlug: "deepwiki",
            serverHost: "mcp.deepwiki.com",
            info: MCPToolInfo(name: "search", description: "", parameters: nil),
            invoker: LedgerFakeInvoker()
        )
        _ = try await proxy.execute(arguments: .object(["q": .string("swift")]))
        let event = try XCTUnwrap(PrivacyLedger.shared.events.last)
        XCTAssertEqual(event.destination, .mcpServer(name: "deepwiki", host: "mcp.deepwiki.com"))
        XCTAssertTrue(event.payloadSummary.contains("search"), event.payloadSummary)
    }

    func testEscalateRecordsSanitizedCloudEgress() async throws {
        // Give the tool an API key so it actually attempts to send (and records).
        let keyName = "gemini_api_key"
        let saved = KeychainStore.shared.string(forKey: keyName)
        KeychainStore.shared.set("AIza-test-key", forKey: keyName)
        defer { KeychainStore.shared.set(saved ?? "", forKey: keyName) }

        PrivacyLedger.shared.beginTurn()
        let tool = EscalateToGeminiTool(geminiClient: GeminiClient(session: stubbedSession()))
        _ = try await tool.execute(arguments: .object([
            "task": .string("Email me at john@example.com about the plan"),
        ]))

        let event = try XCTUnwrap(PrivacyLedger.shared.events.last)
        XCTAssertEqual(event.destination, .cloud(model: GeminiClient.modelName))
        XCTAssertEqual(event.redactions, 1)                                   // the email
        XCTAssertTrue(event.payloadSummary.contains("[EMAIL]"), event.payloadSummary)
        XCTAssertFalse(event.payloadSummary.contains("john@example.com"))     // PII never logged
    }
}
