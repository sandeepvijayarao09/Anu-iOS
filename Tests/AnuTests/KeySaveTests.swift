import XCTest
@testable import Anu

/// A key typed in Settings is saved, or kept with the reason it wasn't,
/// never silently dropped.
final class KeySaveTests: XCTestCase {
    /// A keychain that refuses every write, as an unsigned build's does.
    private final class RefusingBackend: VaultBackend, @unchecked Sendable {
        func write(_ data: Data, account: String, protection: VaultProtection) throws {
            throw VaultError.storage(-34018)
        }
        func read(account: String, reason: String?) throws -> Data? { nil }
        func delete(account: String) {}
    }

    func testASavedKeyIsClearedFromTheField() {
        let vault = Vault(backend: InMemoryVaultBackend())
        var typed = "test-key-not-real"
        XCTAssertNil(KnownSecret.gemini.save(typed: &typed, in: vault))
        XCTAssertEqual(typed, "")
        XCTAssertTrue(vault.contains(.gemini))
    }

    func testAFailedSaveKeepsTheKeyAndSaysWhy() throws {
        let vault = Vault(backend: RefusingBackend())
        var typed = "test-key-not-real"
        let why = try XCTUnwrap(KnownSecret.braveSearch.save(typed: &typed, in: vault))
        XCTAssertEqual(typed, "test-key-not-real", "kept so it can be tried again")
        XCTAssertTrue(why.hasPrefix("Couldn't save the \(KnownSecret.braveSearch.label)"), why)
        XCTAssertFalse(why.contains("test-key-not-real"), "the key is never shown in the message")
        XCTAssertFalse(vault.contains(.braveSearch))
    }

    func testAnEmptyFieldSavesNothing() {
        let vault = Vault(backend: RefusingBackend())
        var typed = ""
        XCTAssertNil(KnownSecret.gemini.save(typed: &typed, in: vault))
    }
}
