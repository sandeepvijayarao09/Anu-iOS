import CryptoKit
import Foundation
import OSLog
import Security

// Encrypted store files (Android parity: `core:data` on SQLCipher, ARCHITECTURE
// §14 — "encrypted at rest", "excluded from backup and device transfer").
//
// Every personal-data store (chats, the session index, memory, the privacy
// ledger, the tool audit) writes through `SecureFile`:
//  - AES-256-GCM with a per-install key kept in the Keychain as
//    `ThisDeviceOnly`, so the key never reaches a backup or another phone;
//  - `.completeFileProtection` on top, as before;
//  - the file is excluded from iCloud / Finder backups.
// Files written by earlier builds (plain JSON) still load and are encrypted
// the next time they're saved.

/// Supplies the data key. `nil` means this process has no Keychain at all
/// (an unsigned build): files then keep the previous protection only.
protocol DataKeyProviding: Sendable {
    func dataKey() throws -> SymmetricKey?
}

/// The app's data key, created on first use.
final class KeychainDataKey: DataKeyProviding, @unchecked Sendable {
    static let shared = KeychainDataKey()

    private let service = "com.anu.app.vault"
    private let account = "data.key"
    private let lock = NSLock()
    private var cached: SymmetricKey?
    private var unavailable = false

    func dataKey() throws -> SymmetricKey? {
        try lock.withLock {
            if let cached { return cached }
            if unavailable { return nil }
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            var status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data, data.count == 32 {
                cached = SymmetricKey(data: data)
                return cached
            }
            if status == errSecMissingEntitlement { unavailable = true; return nil }
            guard status == errSecItemNotFound else { throw SecureFileError.keychain(status) }

            let key = SymmetricKey(size: .bits256)
            let bytes = key.withUnsafeBytes { Data($0) }
            query.removeValue(forKey: kSecReturnData as String)
            query.removeValue(forKey: kSecMatchLimit as String)
            query[kSecValueData as String] = bytes
            // Readable after first unlock so a save that races the screen
            // locking still finds the key; the files themselves are
            // `.completeFileProtection`.
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecMissingEntitlement { unavailable = true; return nil }
            guard status == errSecSuccess else { throw SecureFileError.keychain(status) }
            cached = key
            return key
        }
    }
}

/// A fixed key, for tests.
struct StaticDataKey: DataKeyProviding {
    let key: SymmetricKey?
    func dataKey() throws -> SymmetricKey? { key }
}

enum SecureFileError: Error, Equatable {
    case keychain(OSStatus)
    case undecryptable
}

enum SecureFile {
    /// Marks an encrypted file: "ANU" + format version 1.
    static let magic = Data("ANUE1".utf8)
    private static let context = Data("anu.store.v1".utf8)
    private static let log = Logger(subsystem: "com.anu.app", category: "SecureFile")

    /// Encrypts and writes `data` atomically, then excludes it from backup.
    static func write(_ data: Data, to url: URL, keys: DataKeyProviding = KeychainDataKey.shared) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload: Data
        if let key = try keys.dataKey() {
            let sealed = try AES.GCM.seal(data, using: key, authenticating: context)
            guard let combined = sealed.combined else { throw SecureFileError.undecryptable }
            payload = magic + combined
        } else {
            log.error("No Keychain in this build; \(url.lastPathComponent, privacy: .public) keeps file protection only")
            payload = data
        }
        try payload.write(to: url, options: [.atomic, .completeFileProtection])
        excludeFromBackup(url)
    }

    /// Reads and decrypts. Plain files from earlier builds are returned as-is.
    /// Returns nil when the file is missing or can't be decrypted (a wrong
    /// key or a tampered file never yields partial data).
    static func read(_ url: URL, keys: DataKeyProviding = KeychainDataKey.shared) -> Data? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        guard raw.starts(with: magic) else { return raw }
        do {
            guard let key = try keys.dataKey() else { return nil }
            let box = try AES.GCM.SealedBox(combined: raw.dropFirst(magic.count))
            return try AES.GCM.open(box, using: key, authenticating: context)
        } catch {
            log.error("Couldn't decrypt \(url.lastPathComponent, privacy: .public)")
            return nil
        }
    }

    static func isEncrypted(_ url: URL) -> Bool {
        (try? Data(contentsOf: url))?.starts(with: magic) ?? false
    }

    static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }
}
