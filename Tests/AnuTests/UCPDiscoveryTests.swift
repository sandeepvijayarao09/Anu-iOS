import XCTest
@testable import Anu

private final class UCPStubProtocol: URLProtocol {
    static var json = ""
    static var lastURL: URL?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        UCPStubProtocol.lastURL = request.url
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(UCPStubProtocol.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class UCPDiscoveryTests: XCTestCase {

    // MARK: well-known URL

    func testWellKnownURLFromBareDomain() {
        XCTAssertEqual(UCPDiscovery.wellKnownURL(forDomain: "shop.example.com")?.absoluteString,
                       "https://shop.example.com/.well-known/ucp")
    }

    func testWellKnownURLStripsSchemeAndPath() {
        XCTAssertEqual(UCPDiscovery.wellKnownURL(forDomain: "https://shop.example.com/store")?.absoluteString,
                       "https://shop.example.com/.well-known/ucp")
    }

    // MARK: tolerant parsing

    func testParsesBindingsArray() {
        let doc = """
        {"capabilities":["checkout"],"bindings":[{"type":"rest","url":"https://x/rest"},{"type":"mcp","url":"https://shop.example/mcp"}]}
        """
        XCTAssertEqual(UCPDiscovery.parseMCPEndpoint(from: Data(doc.utf8)), "https://shop.example/mcp")
    }

    func testParsesKeyedMCPObject() {
        let doc = #"{"transports":{"mcp":{"url":"https://m.example/mcp"}}}"#
        XCTAssertEqual(UCPDiscovery.parseMCPEndpoint(from: Data(doc.utf8)), "https://m.example/mcp")
    }

    func testParsesKeyedMCPString() {
        let doc = #"{"mcp":"https://m2.example/mcp"}"#
        XCTAssertEqual(UCPDiscovery.parseMCPEndpoint(from: Data(doc.utf8)), "https://m2.example/mcp")
    }

    func testNoMCPBindingReturnsNil() {
        let doc = #"{"bindings":[{"type":"rest","url":"https://x/rest"}]}"#
        XCTAssertNil(UCPDiscovery.parseMCPEndpoint(from: Data(doc.utf8)))
    }

    func testNonJSONReturnsNil() {
        XCTAssertNil(UCPDiscovery.parseMCPEndpoint(from: Data("not json".utf8)))
    }

    // MARK: discover end-to-end (stubbed)

    func testDiscoverProducesOAuthConfig() async throws {
        UCPStubProtocol.json = #"{"bindings":[{"type":"mcp","url":"https://shop.example/mcp"}]}"#
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UCPStubProtocol.self]
        let ucp = UCPDiscovery(session: URLSession(configuration: config))

        let result = try await ucp.discover(merchantDomain: "shop.example")
        XCTAssertEqual(result?.endpoint, "https://shop.example/mcp")
        XCTAssertEqual(result?.auth, .oauth)
        XCTAssertEqual(UCPStubProtocol.lastURL?.absoluteString, "https://shop.example/.well-known/ucp")
    }
}
