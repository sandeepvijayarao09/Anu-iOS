import XCTest
@testable import Anu

// MARK: - Stubs

private final class StubURLProtocol: URLProtocol {
    static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        StubURLProtocol.lastRequest = request
        let url = request.url ?? URL(string: "https://x")!
        let (response, data) = StubURLProtocol.responder?(request)
            ?? (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private extension URLRequest {
    var capturedBody: Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(); let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private struct StubAttestation: DeviceAttesting {
    var supported: Bool
    var headerFields: [String: String]
    var isSupported: Bool { supported }
    func ensureAttested() async throws -> String { "test-key" }
    func headers(forBody body: Data) async throws -> AttestationHeaders { AttestationHeaders(fields: headerFields) }
}

// MARK: - Tests

final class PrivateComputeClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        KeychainStore.shared.set("https://pcs.test/api", forKey: "pcs_endpoint")
    }
    override func tearDown() {
        KeychainStore.shared.remove(forKey: "pcs_endpoint")
        StubURLProtocol.responder = nil
        StubURLProtocol.lastRequest = nil
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeClient(headers: [String: String] = ["X-Key-Id": "k", "X-Device-Assertion": "a"]) -> PrivateComputeClient {
        PrivateComputeClient(session: makeSession(),
                             attestation: StubAttestation(supported: true, headerFields: headers))
    }

    func testSSEParserExtractsDeltaAndSkipsDone() {
        XCTAssertEqual(PrivateComputeSSEParser.extractText(from: SSEEvent(data: "{\"delta\":\"hi\"}")), "hi")
        XCTAssertNil(PrivateComputeSSEParser.extractText(from: SSEEvent(data: "[DONE]")))
        XCTAssertNil(PrivateComputeSSEParser.extractText(from: SSEEvent(data: "not json")))
    }

    func testNonStreamingReturnsText() async throws {
        StubURLProtocol.responder = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("{\"text\":\"hello world\"}".utf8))
        }
        let text = try await makeClient().generate(prompt: "hi", sessionId: "s", config: .deterministic, recordsLedger: false)
        XCTAssertEqual(text, "hello world")
    }

    func testUnauthorizedMapsToError() async {
        StubURLProtocol.responder = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        await assertThrows(.unauthorized) {
            _ = try await self.makeClient().generate(prompt: "hi", sessionId: "s", config: .deterministic, recordsLedger: false)
        }
    }

    func testRateLimitedMapsToError() async {
        StubURLProtocol.responder = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!, Data())
        }
        await assertThrows(.rateLimited) {
            _ = try await self.makeClient().generate(prompt: "hi", sessionId: "s", config: .deterministic, recordsLedger: false)
        }
    }

    func testRequestCarriesAttestationHeaderAndSessionId() async throws {
        StubURLProtocol.responder = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("{\"text\":\"ok\"}".utf8))
        }
        _ = try await makeClient(headers: ["X-Key-Id": "abc", "X-Device-Assertion": "sig"])
            .generate(prompt: "hi", sessionId: "sandbox-1", config: .deterministic, recordsLedger: false)
        let req = StubURLProtocol.lastRequest
        XCTAssertEqual(req?.value(forHTTPHeaderField: "X-Key-Id"), "abc")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "X-Device-Assertion"), "sig")
        let body = String(data: req?.capturedBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("sandbox-1"), "request body should carry the session id")
    }

    func testDevTokenFallbackHeaderUsedWhenUnsupported() async throws {
        StubURLProtocol.responder = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("{\"text\":\"ok\"}".utf8))
        }
        let client = PrivateComputeClient(
            session: makeSession(),
            attestation: StubAttestation(supported: false, headerFields: ["Authorization": "Bearer dev-xyz"]))
        _ = try await client.generate(prompt: "hi", sessionId: "s", config: .deterministic, recordsLedger: false)
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer dev-xyz")
    }

    func testNonHTTPSEndpointRejected() async {
        KeychainStore.shared.set("http://insecure.test", forKey: "pcs_endpoint")
        await assertThrows(.invalidResponse) {
            _ = try await self.makeClient().generate(prompt: "hi", sessionId: "s", config: .deterministic, recordsLedger: false)
        }
    }

    func testNotConfiguredThrows() async {
        KeychainStore.shared.remove(forKey: "pcs_endpoint")
        await assertThrows(.notConfigured) {
            _ = try await self.makeClient().generate(prompt: "hi", sessionId: "s", config: .deterministic, recordsLedger: false)
        }
    }

    // MARK: helper

    private func assertThrows(_ expected: PrivateComputeError, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)")
        } catch let error as PrivateComputeError {
            XCTAssertEqual(error.errorDescription, expected.errorDescription)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
