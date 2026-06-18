import XCTest
@testable import Anu

/// App Attest can't run in the simulator, so these exercise the mandatory
/// dev-token fallback path (the only path reachable in CI).
final class DeviceAttestationTests: XCTestCase {

    override func tearDown() {
        KeychainStore.shared.remove(forKey: DeviceAttestation.devTokenKey)
        super.tearDown()
    }

    func testEnsureAttestedReturnsDevWhenUnsupported() async throws {
        let attest = DeviceAttestation.shared
        try XCTSkipIf(attest.isSupported, "App Attest is supported here; fallback path not exercised")
        let id = try await attest.ensureAttested()
        XCTAssertEqual(id, "dev")
    }

    func testDevTokenBecomesBearerHeader() async throws {
        let attest = DeviceAttestation.shared
        try XCTSkipIf(attest.isSupported, "App Attest is supported here; fallback path not exercised")
        KeychainStore.shared.set("dev-abc", forKey: DeviceAttestation.devTokenKey)
        let headers = try await attest.headers(forBody: Data("body".utf8))
        XCTAssertEqual(headers.fields["Authorization"], "Bearer dev-abc")
    }

    func testNoDevTokenYieldsEmptyHeaders() async throws {
        let attest = DeviceAttestation.shared
        try XCTSkipIf(attest.isSupported, "App Attest is supported here; fallback path not exercised")
        KeychainStore.shared.remove(forKey: DeviceAttestation.devTokenKey)
        let headers = try await attest.headers(forBody: Data())
        XCTAssertTrue(headers.fields.isEmpty)
    }
}
