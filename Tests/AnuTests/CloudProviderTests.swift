import XCTest
@testable import Anu

final class CloudProviderTests: XCTestCase {

    override func setUp() { super.setUp(); clear() }
    override func tearDown() { clear(); super.tearDown() }

    private func clear() {
        KeychainStore.shared.remove(forKey: "pcs_endpoint")
        KeychainStore.shared.remove(forKey: "gemini_api_key")
        UserDefaults.standard.removeObject(forKey: CloudProvider.preferenceKey)
    }

    func testAutoPrefersPrivateWhenBothConfigured() {
        KeychainStore.shared.set("https://pcs.test", forKey: "pcs_endpoint")
        KeychainStore.shared.set("AIzaKEY", forKey: "gemini_api_key")
        XCTAssertEqual(CloudProvider.resolved(), .privateCloud)
    }

    func testAutoFallsBackToGemini() {
        KeychainStore.shared.set("AIzaKEY", forKey: "gemini_api_key")
        XCTAssertEqual(CloudProvider.resolved(), .gemini)
    }

    func testAutoLocalOnlyWhenNothingConfigured() {
        XCTAssertNil(CloudProvider.resolved())
    }

    func testPrivatePreferenceRequiresEndpoint() {
        UserDefaults.standard.set("private", forKey: CloudProvider.preferenceKey)
        XCTAssertNil(CloudProvider.resolved())
        KeychainStore.shared.set("https://pcs.test", forKey: "pcs_endpoint")
        XCTAssertEqual(CloudProvider.resolved(), .privateCloud)
    }

    func testGeminiPreferenceIgnoresPrivate() {
        UserDefaults.standard.set("gemini", forKey: CloudProvider.preferenceKey)
        KeychainStore.shared.set("https://pcs.test", forKey: "pcs_endpoint")
        XCTAssertNil(CloudProvider.resolved(), "gemini-only preference ignores a configured private server")
        KeychainStore.shared.set("AIzaKEY", forKey: "gemini_api_key")
        XCTAssertEqual(CloudProvider.resolved(), .gemini)
    }
}
