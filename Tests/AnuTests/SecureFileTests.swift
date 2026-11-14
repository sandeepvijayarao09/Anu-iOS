import CryptoKit
import XCTest
@testable import Anu

/// Encrypted store files (Android parity: encrypted at rest, no backup).
final class SecureFileTests: XCTestCase {
    private var dir: URL!
    private let keys = StaticDataKey(key: SymmetricKey(size: .bits256))

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("securefile-\(UUID().uuidString)")
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private var url: URL { dir.appendingPathComponent("store.json") }
    private let secret = Data(#"{"note":"Priya's birthday is 12 March"}"#.utf8)

    func testRoundTripsAndCiphertextHidesPlaintext() throws {
        try SecureFile.write(secret, to: url, keys: keys)
        let raw = try Data(contentsOf: url)
        XCTAssertTrue(raw.starts(with: SecureFile.magic))
        XCTAssertNil(raw.range(of: Data("Priya".utf8)), "plaintext must not appear on disk")
        XCTAssertEqual(SecureFile.read(url, keys: keys), secret)
    }

    func testEachWriteUsesAFreshNonce() throws {
        try SecureFile.write(secret, to: url, keys: keys)
        let first = try Data(contentsOf: url)
        try SecureFile.write(secret, to: url, keys: keys)
        XCTAssertNotEqual(first, try Data(contentsOf: url))
    }

    func testWrongKeyOrTamperingYieldsNothing() throws {
        try SecureFile.write(secret, to: url, keys: keys)
        XCTAssertNil(SecureFile.read(url, keys: StaticDataKey(key: SymmetricKey(size: .bits256))))

        var raw = try Data(contentsOf: url)
        raw[raw.count - 1] ^= 0xFF
        try raw.write(to: url)
        XCTAssertNil(SecureFile.read(url, keys: keys))
    }

    func testLegacyPlainFileStillLoadsThenEncryptsOnSave() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try secret.write(to: url)
        XCTAssertEqual(SecureFile.read(url, keys: keys), secret)
        XCTAssertFalse(SecureFile.isEncrypted(url))
        try SecureFile.write(secret, to: url, keys: keys)
        XCTAssertTrue(SecureFile.isEncrypted(url))
    }

    func testNoKeychainKeepsDataReadable() throws {
        let none = StaticDataKey(key: nil)
        try SecureFile.write(secret, to: url, keys: none)
        XCTAssertEqual(SecureFile.read(url, keys: none), secret)
    }

    func testExcludedFromBackup() throws {
        try SecureFile.write(secret, to: url, keys: keys)
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testMissingFileIsNil() {
        XCTAssertNil(SecureFile.read(url, keys: keys))
    }

    /// With a real Keychain (signed builds), the ledger store is encrypted on disk.
    func testPrivacyLedgerStoreIsEncryptedOnDisk() throws {
        try requireWorkingKeychain()
        let store = PrivacyLedgerStore(directory: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store.save([])
        XCTAssertTrue(SecureFile.isEncrypted(dir.appendingPathComponent("privacy_ledger.json")))
        XCTAssertEqual(store.load()?.count, 0)
    }
}
