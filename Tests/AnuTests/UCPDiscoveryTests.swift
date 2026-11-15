import XCTest
@testable import Anu

/// Routes stubbed responses by "<METHOD> <path>", defaulting to 404. Lets one
/// test drive both the `/.well-known/ucp` GET and the `initialize` POST probe.
private final class UCPRouteStub: URLProtocol {
    struct Stub { let status: Int; let contentType: String; let body: String }
    static var routes: [String: Stub] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let stub = UCPRouteStub.routes[key]
        let resp = HTTPURLResponse(
            url: request.url!,
            statusCode: stub?.status ?? 404,
            httpVersion: nil,
            headerFields: ["Content-Type": stub?.contentType ?? "text/plain"]
        )!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((stub?.body ?? "").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class UCPDiscoveryTests: XCTestCase {

    override func tearDown() {
        UCPRouteStub.routes = [:]
        super.tearDown()
    }

    private func stubbedDiscovery() -> UCPDiscovery {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UCPRouteStub.self]
        return UCPDiscovery(session: URLSession(configuration: config))
    }

    private static let initResult =
        #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"storefront","version":"1"},"capabilities":{"tools":{}}}}"#

    // MARK: host / well-known URL

    func testHostFromBareDomain() {
        XCTAssertEqual(UCPDiscovery.host(from: "gymshark.com"), "gymshark.com")
    }

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

    func testParsesRealUCPServicesMCPBinding() {
        let doc = #"{"ucp":{"version":"2026-01-11","services":{"dev.ucp.shopping":[{"transport":"rest","endpoint":"https://x/rest"},{"transport":"mcp","endpoint":"https://m.shop/mcp"}]}}}"#
        XCTAssertEqual(UCPDiscovery.parseMCPEndpoint(from: Data(doc.utf8)), "https://m.shop/mcp")
    }

    func testRestOnlyUCPServicesReturnsNil() {
        let doc = #"{"ucp":{"services":{"dev.ucp.shopping":[{"transport":"rest","endpoint":"https://x/rest","schema":"https://ucp.dev/x.json"}]}}}"#
        XCTAssertNil(UCPDiscovery.parseMCPEndpoint(from: Data(doc.utf8)))
    }

    func testParsesKeyedMCPObject() {
        let doc = #"{"transports":{"mcp":{"url":"https://m.example/mcp"}}}"#
        XCTAssertEqual(UCPDiscovery.parseMCPEndpoint(from: Data(doc.utf8)), "https://m.example/mcp")
    }

    func testNonJSONReturnsNil() {
        XCTAssertNil(UCPDiscovery.parseMCPEndpoint(from: Data("not json".utf8)))
    }

    // MARK: initialize-result recognition

    func testIsInitializeResultRawJSON() {
        XCTAssertTrue(UCPDiscovery.isInitializeResult(Data(Self.initResult.utf8)))
    }

    func testIsInitializeResultSSEFrame() {
        let sse = "event: message\ndata: \(Self.initResult)\n\n"
        XCTAssertTrue(UCPDiscovery.isInitializeResult(Data(sse.utf8)))
    }

    func testIsInitializeResultRejectsNonInit() {
        XCTAssertFalse(UCPDiscovery.isInitializeResult(Data(#"{"bindings":[]}"#.utf8)))
        XCTAssertFalse(UCPDiscovery.isInitializeResult(Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601}}"#.utf8)))
    }

    // MARK: discover end-to-end (stubbed)

    func testWellKnownMCPBindingOpenIsNoAuth() async throws {
        UCPRouteStub.routes = [
            "GET /.well-known/ucp": .init(status: 200, contentType: "application/json",
                body: #"{"ucp":{"services":{"dev.ucp.shopping":[{"transport":"mcp","endpoint":"https://shop.example/mcp"}]}}}"#),
            "POST /mcp": .init(status: 200, contentType: "application/json", body: Self.initResult),
        ]
        let config = try await stubbedDiscovery().discover(merchantDomain: "shop.example")
        XCTAssertEqual(config?.endpoint, "https://shop.example/mcp")
        XCTAssertEqual(config?.auth, MCPAuth.none)
        XCTAssertTrue(config?.name.contains("(UCP)") ?? false)
    }

    func testWellKnownMCPBindingGatedIsOAuth() async throws {
        UCPRouteStub.routes = [
            "GET /.well-known/ucp": .init(status: 200, contentType: "application/json",
                body: #"{"ucp":{"services":{"dev.ucp.shopping":[{"transport":"mcp","endpoint":"https://shop.example/mcp"}]}}}"#),
            "POST /mcp": .init(status: 401, contentType: "application/json", body: ""),
        ]
        let config = try await stubbedDiscovery().discover(merchantDomain: "shop.example")
        XCTAssertEqual(config?.endpoint, "https://shop.example/mcp")
        XCTAssertEqual(config?.auth, MCPAuth.oauth)
    }

    func testFallsBackToShopifyStorefront() async throws {
        // No well-known doc; the /api/mcp convention answers initialize openly.
        UCPRouteStub.routes = [
            "POST /api/mcp": .init(status: 200, contentType: "application/json", body: Self.initResult),
        ]
        let config = try await stubbedDiscovery().discover(merchantDomain: "gymshark.com")
        XCTAssertEqual(config?.endpoint, "https://gymshark.com/api/mcp")
        XCTAssertEqual(config?.auth, MCPAuth.none)
        XCTAssertTrue(config?.name.contains("(Shopping)") ?? false)
    }

    func testWellKnownHTMLFallsThroughToStorefront() async throws {
        // A store whose /.well-known/ucp redirects to a plain HTML page still
        // resolves via the storefront convention (here gated → OAuth).
        UCPRouteStub.routes = [
            "GET /.well-known/ucp": .init(status: 200, contentType: "text/html", body: "<html>home</html>"),
            "POST /api/mcp": .init(status: 401, contentType: "application/json", body: ""),
        ]
        let config = try await stubbedDiscovery().discover(merchantDomain: "shop.example")
        XCTAssertEqual(config?.endpoint, "https://shop.example/api/mcp")
        XCTAssertEqual(config?.auth, MCPAuth.oauth)
    }

    func testNoEndpointReturnsNil() async throws {
        // Neither well-known nor storefront present (all 404).
        let config = try await stubbedDiscovery().discover(merchantDomain: "not-a-store.example")
        XCTAssertNil(config)
    }
}
