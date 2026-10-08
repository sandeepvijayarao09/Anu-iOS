import XCTest
@testable import Anu

final class KeychainStoreTests: XCTestCase {
    private var key = ""
    /// Must match `KeychainStore.legacyService` (the pre-rename "GemmaAgent" service).
    private let legacyService = "com.gemmaagent.app"

    override func setUp() {
        super.setUp()
        key = "test_key_\(UUID().uuidString)"
    }

    override func tearDown() {
        KeychainStore.shared.remove(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        deleteLegacy(key)
        super.tearDown()
    }

    // Writes/reads under the legacy service go straight to the store's backend —
    // KeychainStore itself only ever writes under the current service, so the
    // test seeds it directly.
    private var backend: SecretBackend { KeychainStore.shared.backend }

    private func addLegacy(_ value: String, _ key: String) {
        backend.write(Data(value.utf8), service: legacyService, account: key)
    }

    private func legacyValue(_ key: String) -> String? {
        backend.read(service: legacyService, account: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func deleteLegacy(_ key: String) {
        backend.delete(service: legacyService, account: key)
    }

    func testSetAndGet() {
        KeychainStore.shared.set("secret-value", forKey: key)
        XCTAssertEqual(KeychainStore.shared.string(forKey: key), "secret-value")
    }

    func testOverwrite() {
        KeychainStore.shared.set("first", forKey: key)
        KeychainStore.shared.set("second", forKey: key)
        XCTAssertEqual(KeychainStore.shared.string(forKey: key), "second")
    }

    func testMissingKeyReturnsNil() {
        XCTAssertNil(KeychainStore.shared.string(forKey: key))
    }

    func testEmptyStringRemoves() {
        KeychainStore.shared.set("value", forKey: key)
        KeychainStore.shared.set("", forKey: key)
        XCTAssertNil(KeychainStore.shared.string(forKey: key))
    }

    func testRemove() {
        KeychainStore.shared.set("value", forKey: key)
        KeychainStore.shared.remove(forKey: key)
        XCTAssertNil(KeychainStore.shared.string(forKey: key))
    }

    func testMigrationFromUserDefaults() {
        // Legacy value in UserDefaults migrates to the Keychain on first read
        UserDefaults.standard.set("legacy-api-key", forKey: key)

        XCTAssertEqual(KeychainStore.shared.string(forKey: key), "legacy-api-key")
        XCTAssertNil(UserDefaults.standard.string(forKey: key), "legacy value must be removed from UserDefaults")
        // And persists in the Keychain afterwards
        XCTAssertEqual(KeychainStore.shared.string(forKey: key), "legacy-api-key")
    }

    func testMigrationFromPreRenameKeychainService() {
        // A value saved by the old "GemmaAgent" build (legacy Keychain service)
        // must surface — and re-home under the current service — on first read.
        addLegacy("old-gemini-key", key)
        XCTAssertNil(read(currentService: key), "precondition: nothing under the new service yet")

        XCTAssertEqual(KeychainStore.shared.string(forKey: key), "old-gemini-key")
        // Now lives under the current service…
        XCTAssertEqual(read(currentService: key), "old-gemini-key")
        // …and the stale legacy item is removed so it can't shadow future writes.
        XCTAssertNil(legacyValue(key), "legacy Keychain item must be cleared after migration")
        // Stable on subsequent reads.
        XCTAssertEqual(KeychainStore.shared.string(forKey: key), "old-gemini-key")
    }

    func testCurrentServiceWinsOverLegacy() {
        // If both exist, the current-service value is authoritative (no migration).
        addLegacy("stale-old", key)
        KeychainStore.shared.set("current", forKey: key)
        XCTAssertEqual(KeychainStore.shared.string(forKey: key), "current")
    }

    // Reads only the current ("com.anu.app") service, bypassing migration, so a
    // test can assert exactly where a value lives.
    private func read(currentService key: String) -> String? {
        backend.read(service: "com.anu.app", account: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    func testServiceNamesAreStable() {
        // Renaming either would orphan every saved credential.
        XCTAssertEqual(KeychainStore.service, "com.anu.app")
        XCTAssertEqual(KeychainStore.legacyService, legacyService)
    }

    func testDefaultBackendIsSystemKeychainOutsideTests() {
        XCTAssertTrue(KeychainStore.defaultBackend(environment: [:]) is SystemKeychainBackend)
    }

    func testDefaultBackendIsInMemoryUnderXCTest() {
        let env = ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]
        XCTAssertTrue(KeychainStore.defaultBackend(environment: env) is InMemorySecretBackend)
    }

    func testRealKeychainOptInUnderXCTest() {
        let env = ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration", "ANU_TEST_REAL_KEYCHAIN": "1"]
        XCTAssertTrue(KeychainStore.defaultBackend(environment: env) is SystemKeychainBackend)
    }

    func testIsolatedStoresDoNotShareState() {
        let a = KeychainStore(backend: InMemorySecretBackend())
        let b = KeychainStore(backend: InMemorySecretBackend())
        a.set("only-in-a", forKey: key)
        XCTAssertEqual(a.string(forKey: key), "only-in-a")
        XCTAssertNil(b.string(forKey: key))
    }
}
