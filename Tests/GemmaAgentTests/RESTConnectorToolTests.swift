import XCTest
@testable import GemmaAgent

// MARK: - URLProtocol stub

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
    /// URLProtocol delivers POST bodies as a stream; read it back for assertions.
    var capturedBody: Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

final class RESTConnectorToolTests: XCTestCase {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        StubURLProtocol.responder = nil
        StubURLProtocol.lastRequest = nil
        super.tearDown()
    }

    func testGetBuildsURLWithPathAndQuery() async throws {
        StubURLProtocol.responder = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("{\"ok\":true}".utf8))
        }
        let tool = RESTConnectorTool(
            config: RESTConnectorConfig(name: "API", baseURL: "https://api.example.com", method: "GET"),
            session: makeSession()
        )
        let out = try await tool.execute(arguments: .object([
            "path": .string("/users/42"),
            "query": .object(["expand": .string("profile")]),
        ]))
        XCTAssertTrue(out.contains("ok"))
        let url = StubURLProtocol.lastRequest?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("api.example.com/users/42"), url)
        XCTAssertTrue(url.contains("expand=profile"), url)
    }

    func testPostSendsBodyAuthAndContentType() async throws {
        StubURLProtocol.responder = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data("created".utf8))
        }
        let tool = RESTConnectorTool(
            config: RESTConnectorConfig(name: "API", baseURL: "https://api.example.com", method: "POST",
                                        authHeaderName: "Authorization", authHeaderValue: "Bearer tok"),
            session: makeSession()
        )
        let out = try await tool.execute(arguments: .object(["body": .object(["title": .string("hi")])]))
        XCTAssertTrue(out.contains("created"))
        let req = StubURLProtocol.lastRequest
        XCTAssertEqual(req?.httpMethod, "POST")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let bodyText = req?.capturedBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(bodyText.contains("\"title\""), bodyText)
    }

    func testNon2xxReportsStatus() async throws {
        StubURLProtocol.responder = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data("nope".utf8))
        }
        let tool = RESTConnectorTool(
            config: RESTConnectorConfig(name: "API", baseURL: "https://api.example.com"),
            session: makeSession()
        )
        let out = try await tool.execute(arguments: .object([:]))
        XCTAssertTrue(out.contains("404"), out)
    }

    func testGetIsReadOnlyPostIsExternal() {
        let get = RESTConnectorTool(config: RESTConnectorConfig(name: "a", baseURL: "https://a", method: "GET"))
        let post = RESTConnectorTool(config: RESTConnectorConfig(name: "a", baseURL: "https://a", method: "POST"))
        XCTAssertEqual(get.sideEffect, .external(capability: .connector))
        XCTAssertEqual(post.sideEffect, .external(capability: .connector))
    }
}
