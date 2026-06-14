import Foundation
import Security

/// Minimal Keychain wrapper for storing API keys.
/// Apple guidance: credentials belong in the Keychain, not UserDefaults.
final class KeychainStore: Sendable {
    static let shared = KeychainStore()
    private let service = "com.gemmaagent.app"

    private init() {}

    func string(forKey key: String) -> String? {
        // One-time migration of any value previously kept in UserDefaults
        if let legacy = UserDefaults.standard.string(forKey: key), !legacy.isEmpty {
            set(legacy, forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
            return legacy
        }

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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
