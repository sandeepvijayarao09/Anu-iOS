import XCTest
@testable import Anu

final class CloudProviderTests: XCTestCase {

    override func setUpWithError() throws { try requireWorkingKeychain(); clear() }
    override func tearDown() { clear(); super.tearDown() }

    private func clear() {
        KeychainStore.shared.remove(forKey: "pcs_endpoint")
        Vault.shared.delete(.gemini)
        UserDefaults.standard.removeObject(forKey: CloudProvider.preferenceKey)
    }

    func testAutoPrefersPrivateWhenBothConfigured() {
        KeychainStore.shared.set("https://pcs.test", forKey: "pcs_endpoint")
        try? KnownSecret.gemini.store("AIzaKEY")
        XCTAssertEqual(CloudProvider.resolved(), .privateCloud)
    }

    func testAutoFallsBackToGemini() {
        try? KnownSecret.gemini.store("AIzaKEY")
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
        try? KnownSecret.gemini.store("AIzaKEY")
        XCTAssertEqual(CloudProvider.resolved(), .gemini)
    }

    // MARK: - Response-prefix stripping (cloudTurn display)

    func testStripsLeadingProviderPrefix() {
        let gem = CloudProvider.stripResponsePrefix("[Gemini Response]\n\nHello there", usingPrivate: false)
        XCTAssertEqual(gem, "Hello there")
        let priv = CloudProvider.stripResponsePrefix("[Private Compute Response]\n\nHello there", usingPrivate: true)
        XCTAssertEqual(priv, "Hello there")
    }

    func testLeavesPrefixInsideBodyIntact() {
        // A prefix appearing INSIDE the response body must NOT be stripped — only
        // the leading one is removed (a global replace would corrupt this).
        let input = "[Gemini Response]\n\nUse the header [Gemini Response] in your doc"
        let out = CloudProvider.stripResponsePrefix(input, usingPrivate: false)
        XCTAssertEqual(out, "Use the header [Gemini Response] in your doc")
    }

    func testNonMatchingResultPassesThroughTrimmed() {
        // Error/fallback strings (no prefix) are returned as-is, just trimmed.
        let err = CloudProvider.stripResponsePrefix("  Gemini API error: bad key  ", usingPrivate: false)
        XCTAssertEqual(err, "Gemini API error: bad key")
        // Wrong-provider prefix isn't stripped (private prefix vs gemini result).
        let mismatch = CloudProvider.stripResponsePrefix("[Gemini Response]\n\nhi", usingPrivate: true)
        XCTAssertEqual(mismatch, "[Gemini Response]\n\nhi")
    }
}
