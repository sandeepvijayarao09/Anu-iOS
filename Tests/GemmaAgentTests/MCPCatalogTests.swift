import XCTest
@testable import GemmaAgent

final class MCPCatalogTests: XCTestCase {

    func testEntriesAreWellFormed() {
        XCTAssertFalse(MCPCatalog.entries.isEmpty)
        for entry in MCPCatalog.entries {
            XCTAssertFalse(entry.name.isEmpty, "name empty")
            XCTAssertFalse(entry.description.isEmpty, "description empty for \(entry.name)")
            XCTAssertTrue(entry.endpoint.hasPrefix("https://"), "endpoint not https: \(entry.endpoint)")
            XCTAssertFalse(entry.category.isEmpty)
        }
    }

    func testEndpointsAreUnique() {
        let endpoints = MCPCatalog.entries.map(\.endpoint)
        XCTAssertEqual(Set(endpoints).count, endpoints.count, "duplicate catalog endpoints")
    }

    func testMakeConfigPreservesAuthAndEndpoint() {
        for entry in MCPCatalog.entries {
            let config = entry.makeConfig()
            XCTAssertEqual(config.endpoint, entry.endpoint)
            XCTAssertEqual(config.auth, entry.auth)
        }
    }

    func testByCategoryCoversEveryEntry() {
        let grouped = MCPCatalog.byCategory.flatMap { $0.entries }
        XCTAssertEqual(Set(grouped.map(\.id)), Set(MCPCatalog.entries.map(\.id)))
    }
}
