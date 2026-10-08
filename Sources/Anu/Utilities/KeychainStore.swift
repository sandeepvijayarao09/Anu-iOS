import Foundation
import Security

/// Raw storage for secret strings, keyed by (service, account).
/// `KeychainStore` owns the policy (migrations, empty-means-delete); a backend
/// only stores bytes. Splitting the two lets the test suite run headless
/// (CI, unsigned simulator hosts) where the real Keychain is unavailable.
protocol SecretBackend: Sendable {
    func read(service: String, account: String) -> Data?
    func write(_ data: Data, service: String, account: String)
    func delete(service: String, account: String)
}

/// The real thing: generic-password items in the iOS Keychain.
struct SystemKeychainBackend: SecretBackend {
    func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func write(_ data: Data, service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Process-local secret storage. Used by the unit tests so they never depend
/// on Keychain entitlements; never selected in a normal app launch.
final class InMemorySecretBackend: SecretBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    private func slot(_ service: String, _ account: String) -> String { service + "\u{1F}" + account }

    func read(service: String, account: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[slot(service, account)]
    }

    func write(_ data: Data, service: String, account: String) {
        lock.lock(); defer { lock.unlock() }
        items[slot(service, account)] = data
    }

    func delete(service: String, account: String) {
        lock.lock(); defer { lock.unlock() }
        items[slot(service, account)] = nil
    }
}

/// Minimal Keychain wrapper for storing API keys.
/// Apple guidance: credentials belong in the Keychain, not UserDefaults.
final class KeychainStore: Sendable {
    static let shared = KeychainStore(backend: KeychainStore.defaultBackend())

    static let service = "com.anu.app"
    /// Pre-rename Keychain service. The product shipped as "GemmaAgent" before
    /// the 2026-06-14 rename to "Anu"; keys saved by those builds (Gemini API
    /// key, private-compute endpoint, dev token, etc.) live under this service.
    /// They're migrated to `service` on first read so the rename doesn't
    /// silently drop the user's credentials.
    static let legacyService = "com.gemmaagent.app"

    let backend: SecretBackend
    private let defaults: UserDefaults

    init(backend: SecretBackend, defaults: UserDefaults = .standard) {
        self.backend = backend
        self.defaults = defaults
    }

    /// The system Keychain, except when the process is hosting XCTest: an
    /// unsigned simulator test host has no keychain access group, so every
    /// read would come back nil. Set `ANU_TEST_REAL_KEYCHAIN=1` to run the
    /// tests against the real Keychain on a signed host.
    static func defaultBackend(environment: [String: String] = ProcessInfo.processInfo.environment) -> SecretBackend {
        let underTest = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
        if underTest && environment["ANU_TEST_REAL_KEYCHAIN"] != "1" {
            return InMemorySecretBackend()
        }
        return SystemKeychainBackend()
    }

    func string(forKey key: String) -> String? {
        // One-time migration of any value previously kept in UserDefaults
        if let legacy = defaults.string(forKey: key), !legacy.isEmpty {
            set(legacy, forKey: key)
            defaults.removeObject(forKey: key)
            return legacy
        }

        if let value = read(forKey: key, service: Self.service) {
            return value
        }

        // One-time migration from the pre-rename ("GemmaAgent") Keychain service:
        // re-home the value under the new service and drop the stale item.
        if let legacy = read(forKey: key, service: Self.legacyService) {
            set(legacy, forKey: key)
            backend.delete(service: Self.legacyService, account: key)
            return read(forKey: key, service: Self.service)
        }

        return nil
    }

    func set(_ value: String, forKey key: String) {
        guard !value.isEmpty else {
            remove(forKey: key)
            return
        }
        backend.write(Data(value.utf8), service: Self.service, account: key)
    }

    func remove(forKey key: String) {
        backend.delete(service: Self.service, account: key)
    }

    private func read(forKey key: String, service: String) -> String? {
        backend.read(service: service, account: key).flatMap { String(data: $0, encoding: .utf8) }
    }
}
