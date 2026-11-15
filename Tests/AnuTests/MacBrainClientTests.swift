import XCTest
@testable import Anu

/// Stubbed HTTP for the Mac brain and A2A tests: a handler per test answers
/// each request and every request is kept (with its body, which URLProtocol
/// moves into a stream).
final class LANStub: URLProtocol {
    struct Reply {
        var status = 200
        var body = ""
        var headers: [String: String] = ["Content-Type": "application/json"]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (URLRequest) -> Reply = { _ in Reply() }
    nonisolated(unsafe) private static var _requests: [(URLRequest, Data)] = []

    static func answer(_ handler: @escaping (URLRequest) -> Reply) {
        lock.withLock { _handler = handler; _requests = [] }
    }
    static var requests: [(request: URLRequest, body: Data)] {
        lock.withLock { _requests.map { (request: $0.0, body: $0.1) } }
    }
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LANStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let reply: Reply = Self.lock.withLock {
            Self._requests.append((request, body))
            return Self._handler(request)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The user's Mac as the top model (ADR-113): streaming `/api/chat`, the egress
/// gate (sanitized + ledgered with the Mac as destination), media refused, tool
/// calls reported and never run, models and health, and the vault rules.
@MainActor
final class MacBrainClientTests: XCTestCase {
    private var vault: Vault!
    private var ledger: PrivacyLedger!
    private let lan = MacBrainConfig.parse(address: "192.168.1.20:11434", model: "gemma4:e4b")!

    override func setUp() async throws {
        vault = Vault(backend: InMemoryVaultBackend())
        ledger = PrivacyLedger(persists: false)
        ledger.beginTurn()
        LANStub.answer { _ in .init() }
    }

    private func client(_ config: MacBrainConfig? = nil) -> MacBrainClient {
        MacBrainClient(config: config ?? lan, session: LANStub.session(), vault: vault, ledger: ledger)
    }

    private static let ndjson = [
        #"{"model":"gemma4:e4b","message":{"role":"assistant","content":"Solar ","thinking":"hidden"},"done":false}"#,
        #"{"model":"gemma4:e4b","message":{"role":"assistant","content":"wins."},"done":false}"#,
        #"{"model":"gemma4:e4b","message":{"role":"assistant","content":""},"done":true,"prompt_eval_count":12,"eval_count":3,"prompt_eval_duration":5000000,"eval_duration":9000000}"#,
    ].joined(separator: "\n")

    private func body(_ index: Int = 0) -> [String: JSONValue] {
        let data = LANStub.requests[index].body
        guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [:] }
        return object
    }

    // MARK: Streaming

    func testStreamsTextAndUsageAndDropsReasoning() async throws {
        LANStub.answer { _ in .init(body: Self.ndjson, headers: ["Content-Type": "application/x-ndjson"]) }
        var events: [MacBrainEvent] = []
        for try await event in client().stream(messages: [.user("Solar or wind?")]) { events.append(event) }
        XCTAssertEqual(events, [
            .text("Solar "), .text("wins."),
            .done(MacBrainUsage(inputTokens: 12, outputTokens: 3, readMs: 5, writeMs: 9, model: "gemma4:e4b")),
        ])
        let request = LANStub.requests[0].request
        XCTAssertEqual(request.url?.absoluteString, "http://192.168.1.20:11434/api/chat")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(body()["model"], .string("gemma4:e4b"))
        XCTAssertEqual(body()["stream"], .bool(true))
        XCTAssertEqual(body()["think"], .bool(false), "think is always sent, false unless asked for")
    }

    func testGenerateJoinsTheAnswer() async throws {
        LANStub.answer { _ in .init(body: Self.ndjson) }
        let answer = try await client().generate(prompt: "Solar or wind?")
        XCTAssertEqual(answer, "Solar wins.")
    }

    // MARK: Egress gate

    func testPersonalDataIsRedactedAndLedgeredWithTheMacAsDestination() async throws {
        LANStub.answer { _ in .init(body: Self.ndjson) }
        _ = try await client().generate(prompt: "Email maya.jones@example.com about the plan")

        let sent = String(decoding: LANStub.requests[0].body, as: UTF8.self)
        XCTAssertFalse(sent.contains("maya.jones@example.com"), "the email address never leaves the phone")

        XCTAssertEqual(ledger.events.count, 1)
        let event = try XCTUnwrap(ledger.events.first)
        XCTAssertEqual(event.destination, .mac(host: "192.168.1.20:11434"))
        XCTAssertTrue(event.destination.leavesDevice, "the Mac is off the phone")
        XCTAssertGreaterThanOrEqual(event.redactions, 1)
        XCTAssertFalse(event.payloadSummary.contains("maya.jones@example.com"))
        XCTAssertEqual(event.destination.displayName, "Your Mac")
    }

    func testPhotosAreRefusedBeforeAnythingIsSent() async {
        do {
            for try await _ in client().stream(messages: [.user("What's in this?")], attachments: [Data([0xFF, 0xD8])]) {}
            XCTFail("a photo must not go to the Mac")
        } catch {
            XCTAssertEqual(error as? MacBrainError, .mediaStaysOnPhone)
        }
        XCTAssertTrue(LANStub.requests.isEmpty, "nothing reached the network")
        XCTAssertTrue(ledger.events.isEmpty, "nothing left, so nothing is ledgered")
    }

    func testPlainHTTPToAPublicAddressIsRefused() {
        XCTAssertNil(MacBrainConfig.parse(address: "8.8.8.8:11434"))
        XCTAssertNil(MacBrainConfig.parse(address: "http://mac.example.com:11434"))
        XCTAssertNotNil(MacBrainConfig.parse(address: "studio.local"))
        XCTAssertNotNil(MacBrainConfig.parse(address: "10.0.0.5"))
        XCTAssertEqual(MacBrainConfig.parse(address: "studio.local")?.baseURL.absoluteString, "http://studio.local:11434")
        XCTAssertTrue(LocalNetwork.isLocal("172.20.1.1"))
        XCTAssertFalse(LocalNetwork.isLocal("172.32.1.1"))
        XCTAssertTrue(LocalNetwork.isLocal("fe80::1"))
    }

    // MARK: Tool calls (ADR-017)

    func testToolsAreSentAsFunctionsAndCallsAreReportedNotRun() async throws {
        let call = #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"calculator","arguments":{"expression":"2+2"}}}]},"done":false}"#
        let done = #"{"message":{"role":"assistant","content":""},"done":true}"#
        LANStub.answer { _ in .init(body: call + "\n" + done) }
        var events: [MacBrainEvent] = []
        for try await event in client().stream(messages: [.user("2+2?")], tools: [CalculatorTool()]) {
            events.append(event)
        }
        XCTAssertEqual(events.first, .toolCall(name: "calculator", arguments: .object(["expression": .string("2+2")])))

        guard case .array(let tools)? = body()["tools"], let first = tools.first else { return XCTFail("no tools sent") }
        XCTAssertEqual(first["type"], .string("function"))
        XCTAssertEqual(first["function"]?["name"], .string("calculator"))
        XCTAssertNotNil(first["function"]?["parameters"]?["properties"])
    }

    func testGenerateNeverRunsAProposedTool() async throws {
        let call = #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"send_message","arguments":"{\"to\":\"x\"}"}}]},"done":true}"#
        LANStub.answer { _ in .init(body: call) }
        let answer = try await client().generate(prompt: "Text Maya")
        XCTAssertTrue(answer.contains("send_message"))
        XCTAssertTrue(answer.contains("nothing was run"))
        XCTAssertEqual(LANStub.requests.count, 1, "only the chat request: no tool ran")
    }

    func testArgumentsSentAsAStringAreDecoded() throws {
        let line = #"{"message":{"tool_calls":[{"function":{"name":"t","arguments":"{\"a\":1}"}}]},"done":false}"#
        XCTAssertEqual(try MacBrainClient.events(fromLine: line), [.toolCall(name: "t", arguments: .object(["a": .int(1)]))])
    }

    // MARK: Errors

    func testErrorLineThrowsWithTheMacsMessage() async {
        LANStub.answer { _ in .init(body: #"{"error":"model 'gemma4:26b' not found"}"#) }
        do {
            _ = try await client().generate(prompt: "hi")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MacBrainError, .server("model 'gemma4:26b' not found"))
        }
    }

    func testHTTPErrorsMap() async {
        LANStub.answer { _ in .init(status: 401, body: #"{"error":"wrong token"}"#) }
        do { _ = try await client().generate(prompt: "hi"); XCTFail() } catch {
            XCTAssertEqual(error as? MacBrainError, .unauthorized)
        }
        LANStub.answer { _ in .init(status: 500, body: #"{"error":"boom"}"#) }
        do { _ = try await client().generate(prompt: "hi"); XCTFail() } catch {
            XCTAssertEqual(error as? MacBrainError, .http(500, "boom"))
        }
    }

    func testNotConfigured() async {
        let none = MacBrainClient(config: nil, session: LANStub.session(), vault: vault, ledger: ledger)
        XCTAssertFalse(none.isConfigured)
        do { _ = try await none.generate(prompt: "hi"); XCTFail() } catch {
            XCTAssertEqual(error as? MacBrainError, .notConfigured)
        }
    }

    // MARK: Models and health

    func testModelsFromOllamaTags() async throws {
        LANStub.answer { request in
            XCTAssertEqual(request.url?.path, "/api/tags")
            return .init(body: #"{"models":[{"name":"gemma4:e4b"},{"name":"gemma4:26b"}]}"#)
        }
        let models = try await client().models()
        XCTAssertEqual(models, ["gemma4:26b", "gemma4:e4b"])
        XCTAssertEqual(ledger.events.first?.payloadSummary, "GET /api/tags", "a status check is ledgered, with no content")
    }

    func testHealthReportsOllamaVersion() async throws {
        LANStub.answer { request in
            request.url?.path == "/api/version"
                ? .init(body: #"{"version":"0.12.3"}"#)
                : .init(body: #"{"models":[{"name":"gemma4:e4b"}]}"#)
        }
        let health = try await client().health()
        XCTAssertEqual(health, .init(summary: "Ollama 0.12.3", models: ["gemma4:e4b"]))
    }

    func testHealthFallsBackToTheGatewayPing() async throws {
        let pin = String(repeating: "ab", count: 32)
        let paired = MacBrainConfig.parse(address: "https://192.168.1.20:11435", pin: pin)!
        try MacPairing.storeToken(String(repeating: "t", count: 43), for: paired, in: vault)
        LANStub.answer { request in
            request.url?.path == "/anu/ping"
                ? .init(body: #"{"model":"gemma4:26b","context":32768}"#)
                : .init(status: 404, body: #"{"error":"only /api/chat"}"#)
        }
        let health = try await client(paired).health()
        XCTAssertEqual(health, .init(summary: "mac-brain.py · gemma4:26b", models: ["gemma4:26b"]))
    }

    // MARK: Vault rules

    func testNoSecretGoesOverPlainHTTP() async throws {
        // Even with a token stored for this host, plain HTTP carries none.
        try vault.store(String(repeating: "t", count: 40), ref: .macBrain, kind: .apiKey, label: "Mac token",
                        service: "Your Mac", boundHosts: ["192.168.1.20"], allowedUsers: [VaultCaller.macBrain])
        LANStub.answer { _ in .init(body: Self.ndjson) }
        _ = try await client().generate(prompt: "hi")
        XCTAssertNil(LANStub.requests[0].request.value(forHTTPHeaderField: "Authorization"))
    }

    func testPairedHTTPSSendsTheVaultTokenToThePairedHostOnly() async throws {
        let token = String(repeating: "k", count: 43)
        let pin = String(repeating: "0f", count: 32)
        let code = try XCTUnwrap(MacPairing.parse("anu-mac://192.168.1.20:11435?pin=\(pin)&token=\(token)"))
        XCTAssertEqual(code.token, token)
        XCTAssertEqual(code.config.pin, pin)
        XCTAssertEqual(code.config.baseURL.absoluteString, "https://192.168.1.20:11435")
        try MacPairing.storeToken(code.token, for: code.config, in: vault)

        LANStub.answer { _ in .init(body: Self.ndjson) }
        _ = try await client(code.config).generate(prompt: "hi")
        XCTAssertEqual(LANStub.requests[0].request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")

        // The same token for another host is refused by the vault before sending.
        let other = MacBrainConfig.parse(address: "https://192.168.1.99:11435", pin: pin)!
        do { _ = try await client(other).generate(prompt: "hi"); XCTFail() } catch {
            XCTAssertEqual(error as? VaultError, .hostNotBound("192.168.1.99"))
        }
        XCTAssertEqual(LANStub.requests.count, 1)
    }

    func testPairingCodeRejectsBadInput() {
        XCTAssertNil(MacPairing.parse("https://192.168.1.20:11435?pin=\(String(repeating: "a", count: 64))&token=\(String(repeating: "t", count: 40))"))
        XCTAssertNil(MacPairing.parse("anu-mac://192.168.1.20:11435?pin=short&token=\(String(repeating: "t", count: 40))"))
        XCTAssertNil(MacPairing.parse("anu-mac://192.168.1.20:11435?pin=\(String(repeating: "a", count: 64))&token=short"))
    }

    func testCertificatePinIsTheSHA256OfTheCertificate() {
        XCTAssertEqual(MacBrainTransport.sha256(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: Escalation tool + cloud turn

    func testEscalateToMacToolAnswersWithItsPrefix() async throws {
        LANStub.answer { _ in .init(body: Self.ndjson) }
        let tool = EscalateToMacTool(makeClient: { [vault, ledger, lan] in
            MacBrainClient(config: lan, session: LANStub.session(), vault: vault!, ledger: ledger)
        })
        let result = try await tool.execute(arguments: .object(["task": .string("Solar or wind?")]))
        XCTAssertEqual(result, "[Your Mac Response]\n\nSolar wins.")
        XCTAssertEqual(CloudProvider.mac.stripResponsePrefix(result), "Solar wins.")
        XCTAssertEqual(tool.risk(for: .object([:])), .read, "same tier as the other escalation tools")
    }

    func testEscalateToMacToolWithoutAMacSaysSo() async throws {
        let tool = EscalateToMacTool(makeClient: { [vault, ledger] in
            MacBrainClient(config: nil, session: LANStub.session(), vault: vault!, ledger: ledger)
        })
        let result = try await tool.execute(arguments: .object(["task": .string("hi")]))
        XCTAssertTrue(result.hasPrefix("[Your Mac unavailable"))
        XCTAssertTrue(LANStub.requests.isEmpty)
    }

    func testCloudTurnGoesToTheMacWhenItIsTheProvider() async throws {
        let defaults = UserDefaults.standard
        defaults.set("mac", forKey: CloudProvider.preferenceKey)
        lan.save(defaults)
        defer {
            MacBrainConfig.clear(defaults)
            defaults.removeObject(forKey: CloudProvider.preferenceKey)
        }
        XCTAssertEqual(CloudProvider.resolved(), .mac)

        LANStub.answer { _ in .init(body: Self.ndjson) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-\(UUID().uuidString)")
        let orch = AgentOrchestrator(model: ScriptedModel(), sessionsDirectory: dir)
        orch.toolRegistry.register(EscalateToMacTool(makeClient: { [vault, ledger, lan] in
            MacBrainClient(config: lan, session: LANStub.session(), vault: vault!, ledger: ledger)
        }))
        await orch.cloudTurn(userMessage: "Write a long report on solar vs wind for maya.jones@example.com")

        XCTAssertEqual(orch.messages.first { $0.role == .toolCall }?.toolCall?.name, "escalate_to_mac")
        XCTAssertEqual(orch.messages.last { $0.role == .assistant }?.content, "Solar wins.")
        XCTAssertTrue(orch.messages.contains { $0.content.contains("before sending to your Mac") })
        XCTAssertEqual(ledger.events.filter { $0.destination == .mac(host: "192.168.1.20:11434") }.count, 1)
        XCTAssertFalse(String(decoding: LANStub.requests[0].body, as: UTF8.self).contains("maya.jones@example.com"))
    }

    func testMacPreferenceNeedsAnAddress() {
        let defaults = UserDefaults.standard
        defaults.set("mac", forKey: CloudProvider.preferenceKey)
        MacBrainConfig.clear(defaults)
        defer { defaults.removeObject(forKey: CloudProvider.preferenceKey) }
        XCTAssertNil(CloudProvider.resolved())
        XCTAssertEqual(CloudProvider.mac.escalationToolName, "escalate_to_mac")
        XCTAssertEqual(CloudProvider.mac.targetName, "your Mac")
    }
}
