import XCTest
@testable import Anu

final class MCPAuthMigrationTests: XCTestCase {

    func testMCPAuthRoundTrips() throws {
        for auth in [MCPAuth.none, .bearer("tok123"), .oauth] {
            let data = try JSONEncoder().encode(auth)
            XCTAssertEqual(try JSONDecoder().decode(MCPAuth.self, from: data), auth)
        }
    }

    func testNewConfigRoundTrips() throws {
        let config = MCPServerConfig(name: "X", endpoint: "https://x.example/mcp", auth: .oauth)
        let decoded = try JSONDecoder().decode(MCPServerConfig.self,
                                               from: try JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.auth, .oauth)
    }

    func testLegacyAuthTokenMigratesToBearer() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"Old","endpoint":"https://old.example/mcp","authToken":"secret","enabled":true}
        """
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.auth, .bearer("secret"))
    }

    func testLegacyWithoutTokenBecomesNone() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"Open","endpoint":"https://open.example/mcp","enabled":true}
        """
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.auth, .none)
    }
}
