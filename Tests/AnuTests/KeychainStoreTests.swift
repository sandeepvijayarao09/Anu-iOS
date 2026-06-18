import XCTest
@testable import Anu

final class KeychainStoreTests: XCTestCase {
    private var key = ""

    override func setUp() {
        super.setUp()
        key = "test_key_\(UUID().uuidString)"
    }

    override func tearDown() {
        KeychainStore.shared.remove(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
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
}
