import XCTest
@testable import Anu

/// Exercises the larger-model client end-to-end against stubbed HTTP responses:
/// the happy path (response parsing), the no-key guard, and the status-code →
/// `GeminiError` mapping that the escalation path depends on.
final class GeminiClientTests: XCTestCase {

    // Configurable stub: each test sets the status + body it wants returned, and
    // it records the last request so we can assert how the call was built.
    final class Stub: URLProtocol {
        static let lock = NSLock()
        static var _status = 200
        static var _body = Data()
        static var lastRequest: URLRequest?
        static func set(status: Int, body: String) {
            lock.lock(); defer { lock.unlock() }
            _status = status; _body = Data(body.utf8); lastRequest = nil
        }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.lock()
            let status = Self._status, body = Self._body
            Self.lastRequest = request
            Self.lock.unlock()
            let url = request.url ?? URL(string: "https://x")!
            let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeClient() -> GeminiClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return GeminiClient(session: URLSession(configuration: config), vault: vault)
    }

    /// An in-memory vault, so these tests never touch the real Keychain.
    private var vault = Vault(backend: InMemoryVaultBackend())

    override func setUpWithError() throws {
        vault = Vault(backend: InMemoryVaultBackend())
        try KnownSecret.gemini.store("AIza-test-key", in: vault)
    }

    func testGenerateParsesResponseText() async throws {
        Stub.set(status: 200,
                 body: #"{"candidates":[{"content":{"role":"model","parts":[{"text":"Hello from Gemini"}]}}]}"#)
        let text = try await makeClient().generate(prompt: "hi")
        XCTAssertEqual(text, "Hello from Gemini")
    }

    func testNoAPIKeyThrowsBeforeNetwork() async {
        vault.delete(.gemini)
        await assertThrows(.noAPIKey) { try await self.makeClient().generate(prompt: "hi") }
    }

    func testUnauthorizedMaps401() async {
        Stub.set(status: 401, body: "{}")
        await assertThrows(.unauthorized) { try await self.makeClient().generate(prompt: "hi") }
    }

    func testRateLimitedMaps429() async {
        Stub.set(status: 429, body: "{}")
        await assertThrows(.rateLimited) { try await self.makeClient().generate(prompt: "hi") }
    }

    func testEmptyCandidatesIsInvalidResponse() async {
        Stub.set(status: 200, body: #"{"candidates":[]}"#)
        await assertThrows(.invalidResponse) { try await self.makeClient().generate(prompt: "hi") }
    }

    func testServerErrorMapsWithMessageFromBody() async {
        Stub.set(status: 500, body: #"{"error":{"code":500,"message":"backend boom","status":"INTERNAL"}}"#)
        // serverError(500, "backend boom") — verify the code + message surface.
        do {
            _ = try await makeClient().generate(prompt: "hi")
            XCTFail("expected serverError")
        } catch let GeminiError.serverError(code, message) {
            XCTAssertEqual(code, 500)
            XCTAssertEqual(message, "backend boom")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRequestPutsPromptInBodyAndKeyInHeader() async throws {
        Stub.set(status: 200,
                 body: #"{"candidates":[{"content":{"role":"model","parts":[{"text":"ok"}]}}]}"#)
        _ = try await makeClient().generate(prompt: "unique-prompt-marker-42")
        let req = try XCTUnwrap(Stub.lastRequest)
        // The key travels in the x-goog-api-key header and never in the URL,
        // which ends up in logs and proxies. The endpoint is generateContent.
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-goog-api-key"), "AIza-test-key")
        XCTAssertFalse(req.url?.absoluteString.contains("AIza-test-key") == true, req.url?.absoluteString ?? "")
        XCTAssertFalse(req.url?.absoluteString.contains("key=") == true, req.url?.absoluteString ?? "")
        XCTAssertTrue(req.url?.absoluteString.contains(":generateContent") == true, req.url?.absoluteString ?? "")
        XCTAssertEqual(req.httpMethod, "POST")
        // The prompt is carried in the JSON body (read via stream if needed).
        let body = String(data: Self.bodyData(req), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("unique-prompt-marker-42"), body)
    }

    // MARK: - Helpers

    private static func bodyData(_ req: URLRequest) -> Data {
        if let body = req.httpBody { return body }
        guard let stream = req.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }

    private func assertThrows(_ expected: GeminiError,
                              _ body: @escaping () async throws -> String,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as GeminiError {
            XCTAssertEqual(error.errorDescription, expected.errorDescription, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}
