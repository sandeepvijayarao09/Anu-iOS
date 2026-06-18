import XCTest
@testable import Anu

private final class RegistryStubProtocol: URLProtocol {
    static var json = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(RegistryStubProtocol.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class MCPRegistryClientTests: XCTestCase {

    private func client() -> MCPRegistryClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RegistryStubProtocol.self]
        return MCPRegistryClient(session: URLSession(configuration: config))
    }

    func testFiltersToStreamableHTTPAndReadsCursor() async throws {
        RegistryStubProtocol.json = """
        {"servers":[
          {"server":{"name":"a/mcp","title":"Alpha","description":"first","remotes":[{"type":"streamable-http","url":"https://alpha.example/mcp"}]}},
          {"server":{"name":"b","title":"Beta","description":"stdio only","remotes":[{"type":"stdio"}]}},
          {"server":{"name":"c","title":"Gamma","description":"no remotes"}}
        ],"metadata":{"nextCursor":"CUR1","count":3}}
        """
        let (servers, cursor) = try await client().fetch()
        XCTAssertEqual(servers.count, 1, "only the streamable-http entry should survive")
        XCTAssertEqual(servers.first?.endpoint, "https://alpha.example/mcp")
        XCTAssertEqual(servers.first?.title, "Alpha")
        XCTAssertEqual(cursor, "CUR1")
    }

    func testSearchFiltersByText() async throws {
        RegistryStubProtocol.json = """
        {"servers":[
          {"server":{"name":"notion","title":"Notion","description":"docs","remotes":[{"type":"streamable-http","url":"https://n.example/mcp"}]}},
          {"server":{"name":"linear","title":"Linear","description":"issues","remotes":[{"type":"streamable-http","url":"https://l.example/mcp"}]}}
        ],"metadata":{"nextCursor":null,"count":2}}
        """
        let results = try await client().search("linear")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "Linear")
    }

    func testMalformedEntriesTolerated() async throws {
        RegistryStubProtocol.json = """
        {"servers":[{"server":{"name":"ok","remotes":[{"type":"streamable-http","url":"https://ok.example/mcp"}]}}],"metadata":{}}
        """
        let (servers, cursor) = try await client().fetch()
        XCTAssertEqual(servers.count, 1)
        XCTAssertNil(cursor)
    }
}
