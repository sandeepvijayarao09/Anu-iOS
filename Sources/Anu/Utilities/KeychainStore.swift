import Foundation
import Security

/// Minimal Keychain wrapper for storing API keys.
/// Apple guidance: credentials belong in the Keychain, not UserDefaults.
final class KeychainStore: Sendable {
    static let shared = KeychainStore()
    private let service = "com.anu.app"
    /// Pre-rename Keychain service. The product shipped as "GemmaAgent" before
    /// the 2026-06-14 rename to "Anu"; keys saved by those builds (Gemini API
    /// key, private-compute endpoint, dev token, etc.) live under this service.
    /// They're migrated to `service` on first read so the rename doesn't
    /// silently drop the user's credentials.
    private let legacyService = "com.gemmaagent.app"

    private init() {}

    func string(forKey key: String) -> String? {
        // One-time migration of any value previously kept in UserDefaults
        if let legacy = UserDefaults.standard.string(forKey: key), !legacy.isEmpty {
            set(legacy, forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
            return legacy
        }

        if let value = read(forKey: key, service: service) {
            return value
        }

        // One-time migration from the pre-rename ("GemmaAgent") Keychain service:
        // re-home the value under the new service and drop the stale item.
        if let legacy = read(forKey: key, service: legacyService) {
            set(legacy, forKey: key)
            delete(forKey: key, service: legacyService)
            return read(forKey: key, service: service)
        }

        return nil
    }

    func set(_ value: String, forKey key: String) {
        guard !value.isEmpty else {
            remove(forKey: key)
            return
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
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

    func remove(forKey key: String) {
        delete(forKey: key, service: service)
    }

    // MARK: - Private, service-parameterized primitives

    private func read(forKey key: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func delete(forKey key: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
