import XCTest
@testable import Anu

final class ConnectorConfigTests: XCTestCase {

    func testMCPConfigCodableRoundTrip() throws {
        let config = MCPServerConfig(name: "Docs", endpoint: "https://mcp.example.com", auth: .bearer("secret"), enabled: true)
        let data = try JSONEncoder().encode([config])
        let decoded = try JSONDecoder().decode([MCPServerConfig].self, from: data)
        XCTAssertEqual(decoded, [config])
    }

    func testRESTConfigCodableRoundTrip() throws {
        let config = RESTConnectorConfig(name: "Cat Facts", baseURL: "https://catfact.ninja",
                                         method: "post", authHeaderName: "Authorization",
                                         authHeaderValue: "Bearer x", toolDescription: "cats")
        let decoded = try JSONDecoder().decode(RESTConnectorConfig.self,
                                               from: try JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.method, "POST", "method should be uppercased")
    }

    func testRESTIsWrite() {
        XCTAssertFalse(RESTConnectorConfig(name: "a", baseURL: "https://a", method: "GET").isWrite)
        XCTAssertFalse(RESTConnectorConfig(name: "a", baseURL: "https://a", method: "HEAD").isWrite)
        XCTAssertTrue(RESTConnectorConfig(name: "a", baseURL: "https://a", method: "POST").isWrite)
        XCTAssertTrue(RESTConnectorConfig(name: "a", baseURL: "https://a", method: "DELETE").isWrite)
    }

    func testSlugSanitizes() {
        XCTAssertEqual(ConnectorSlug.make("My Cool Server!"), "my_cool_server")
        XCTAssertEqual(ConnectorSlug.make("a//b"), "a_b")
        XCTAssertEqual(ConnectorSlug.make(""), "server")
        XCTAssertEqual(ConnectorSlug.make("Already_clean"), "already_clean")
    }

    func testAppConfigAllows() {
        let config = AppLauncherConfig.default
        XCTAssertTrue(config.allows(scheme: "shortcuts"))
        XCTAssertTrue(config.allows(scheme: "SHORTCUTS"))   // case-insensitive
        XCTAssertFalse(config.allows(scheme: "spotify"))
    }
}
