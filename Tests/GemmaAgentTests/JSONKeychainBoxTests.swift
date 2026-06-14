import XCTest
@testable import GemmaAgent

final class JSONKeychainBoxTests: XCTestCase {

    private struct Sample: Codable, Equatable { let token: String; let n: Int }

    func testSaveLoadClearRoundTrip() {
        let box = JSONKeychainBox<Sample>(key: "test_jsonbox_\(UUID().uuidString)")
        XCTAssertNil(box.load())

        let value = Sample(token: "abc", n: 7)
        box.save(value)
        XCTAssertEqual(box.load(), value)

        box.clear()
        XCTAssertNil(box.load())
    }

    func testOAuthTokenKeyHelpers() {
        let id = UUID()
        XCTAssertFalse(MCPOAuthToken.exists(for: id))
        KeychainStore.shared.set("{\"x\":1}", forKey: MCPOAuthToken.key(for: id))
        XCTAssertTrue(MCPOAuthToken.exists(for: id))
        MCPOAuthToken.clear(for: id)
        XCTAssertFalse(MCPOAuthToken.exists(for: id))
    }
}
