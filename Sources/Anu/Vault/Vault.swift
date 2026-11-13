import Foundation
import LocalAuthentication
import Security

// MARK: - Storage backend

/// Where the vault keeps bytes. The Keychain in the app; memory in tests, so
/// unit tests never touch the real Keychain or show a Face ID prompt.
protocol VaultBackend: AnyObject, Sendable {
    func write(_ data: Data, account: String, protection: VaultProtection) throws
    /// Throws `VaultError.locked` when the user cancels or fails authentication.
    func read(account: String, reason: String?) throws -> Data?
    func delete(account: String)
}

/// Keychain backend. Items are `ThisDeviceOnly`, so they're left out of
/// backups and device transfer (§11 hygiene). `userPresence` items carry an
/// access control that makes iOS ask for Face ID / passcode on every read.
final class KeychainVaultBackend: VaultBackend, @unchecked Sendable {
    private let service: String
    init(service: String = "com.anu.app.vault") { self.service = service }

    func write(_ data: Data, account: String, protection: VaultProtection) throws {
        delete(account: account)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        switch protection {
        case .deviceUnlocked:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .userPresence:
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error
            ) else { throw VaultError.storage(errSecParam) }
            query[kSecAttrAccessControl as String] = access
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.storage(status) }
    }

    func read(account: String, reason: String?) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let context = LAContext()
        if let reason { context.localizedReason = reason } else { context.interactionNotAllowed = true }
        query[kSecUseAuthenticationContext as String] = context
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: throw VaultError.locked
        default: throw VaultError.storage(status)
        }
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// In-memory backend for tests. `lockedAccounts` simulates a cancelled prompt.
final class InMemoryVaultBackend: VaultBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: (Data, VaultProtection)] = [:]
    var lockedAccounts: Set<String> = []

    func write(_ data: Data, account: String, protection: VaultProtection) throws {
        lock.withLock { store[account] = (data, protection) }
    }
    func read(account: String, reason: String?) throws -> Data? {
        try lock.withLock {
            guard let (data, protection) = store[account] else { return nil }
            if protection == .userPresence, reason == nil || lockedAccounts.contains(account) {
                throw VaultError.locked
            }
            return data
        }
    }
    func delete(account: String) { lock.withLock { _ = store.removeValue(forKey: account) } }
    /// Test hook: rewrite raw stored bytes, as tampering outside Anu would.
    func raw(_ account: String) -> Data? { lock.withLock { store[account]?.0 } }
}

// MARK: - Vault

/// Anu's secret store (Android parity §11). Holds only secrets Anu itself
/// uses. Values leave it in exactly two ways:
///  - `authorize(_:use:)` attaches one as a header to an HTTPS request for a
///    bound host, from an allowed caller — the only path code and tools use;
///  - `revealForUser(_:)` for the Vault screen, after Face ID.
final class Vault: ObservableObject, @unchecked Sendable {
    static let shared = Vault(backend: KeychainVaultBackend(), migrateLegacy: true)

    private struct Stored: Codable { let binding: String; let value: String }
    private static let indexAccount = "vault.index"
    private static let activityAccount = "vault.activity"
    private static let activityLimit = 200

    private let backend: VaultBackend
    private let lock = NSRecursiveLock()
    private var index: [VaultItem] = []
    private var log: [VaultActivity] = []
    private let now: () -> Date

    init(backend: VaultBackend, migrateLegacy: Bool = false, now: @escaping () -> Date = Date.init) {
        self.backend = backend
        self.now = now
        index = Self.decode([VaultItem].self, try? backend.read(account: Self.indexAccount, reason: nil)) ?? []
        log = Self.decode([VaultActivity].self, try? backend.read(account: Self.activityAccount, reason: nil)) ?? []
        if migrateLegacy {
            // Test isolation: launch with "-reset_vault YES" to start empty.
            if UserDefaults.standard.bool(forKey: "reset_vault") { removeAll() }
            migrateLegacyKeys()
        }
    }

    /// Deletes every item and the activity log.
    func removeAll() {
        lock.withLock {
            for item in index { backend.delete(account: Self.account(item.ref)) }
            index = []
            log = []
            backend.delete(account: Self.indexAccount)
            backend.delete(account: Self.activityAccount)
        }
    }

    // MARK: Reading metadata (never values)

    var items: [VaultItem] { lock.withLock { index.sorted { $0.label < $1.label } } }
    var activity: [VaultActivity] { lock.withLock { log.reversed() } }

    func item(_ ref: SecretRef) -> VaultItem? { lock.withLock { index.first { $0.id == ref.id } } }
    func contains(_ ref: SecretRef) -> Bool { item(ref) != nil }

    // MARK: Writing

    /// Adds or replaces an item. An empty value removes it.
    @discardableResult
    func store(
        _ value: String, ref: SecretRef, kind: VaultItemKind, label: String, service: String,
        boundHosts: [String], allowedUsers: [String], protection: VaultProtection = .deviceUnlocked
    ) throws -> VaultItem? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { delete(ref); return nil }
        if protection == .deviceUnlocked, !kind.mayUseWithoutPresence { throw VaultError.protectionNotAllowed }
        return try lock.withLock {
            let existing = index.first { $0.id == ref.id }
            let item = VaultItem(
                id: ref.id, kind: kind, label: label, service: service,
                boundHosts: boundHosts.map { $0.lowercased() }, allowedUsers: allowedUsers,
                protection: protection, createdAt: existing?.createdAt ?? now(), lastUsedAt: existing?.lastUsedAt)
            let stored = try JSONEncoder().encode(Stored(binding: item.binding, value: trimmed))
            try backend.write(stored, account: Self.account(ref), protection: protection)
            index.removeAll { $0.id == ref.id }
            index.append(item)
            try saveIndex()
            record(item, caller: "you", host: nil, .added)
            return item
        }
    }

    func delete(_ ref: SecretRef) {
        lock.withLock {
            guard let item = index.first(where: { $0.id == ref.id }) else { return }
            backend.delete(account: Self.account(ref))
            index.removeAll { $0.id == ref.id }
            try? saveIndex()
            record(item, caller: "you", host: nil, .deleted)
        }
    }

    // MARK: Using a secret without exposing it (P3, I1)

    /// Returns `request` with the secret attached as `use.header`, or throws
    /// before anything could be sent. Checks, in order: the item exists, the
    /// request is HTTPS, its host is bound, the caller is allowed, the stored
    /// binding still matches the metadata. Every outcome is audited.
    func authorize(_ request: URLRequest, use: SecretUse) throws -> URLRequest {
        try lock.withLock {
            guard let item = index.first(where: { $0.id == use.ref.id }) else { throw VaultError.notFound(use.ref.id) }
            let host = request.url?.host?.lowercased()
            func refuse(_ error: VaultError) -> VaultError {
                record(item, caller: use.caller, host: host, .refused, reason: error.errorDescription)
                return error
            }
            guard request.url?.scheme?.lowercased() == "https", let host else { throw refuse(.insecureScheme) }
            guard item.boundHosts.contains(host) else { throw refuse(.hostNotBound(host)) }
            guard item.allowedUsers.contains(use.caller) else { throw refuse(.callerNotAllowed(use.caller)) }
            let value: String
            let reason = item.protection == .userPresence ? "Use \(item.label) for \(item.service)" : nil
            do { value = try secretValue(item, reason: reason) } catch let error as VaultError { throw refuse(error) }
            var authorized = request
            authorized.setValue(use.scheme.map { "\($0) \(value)" } ?? value, forHTTPHeaderField: use.header)
            if let i = index.firstIndex(where: { $0.id == item.id }) { index[i].lastUsedAt = now() }
            try? saveIndex()
            record(item, caller: use.caller, host: host, .sent)
            return authorized
        }
    }

    /// For the Vault screen only, after the UI has asked for Face ID.
    func revealForUser(_ ref: SecretRef, reason: String = "Show this secret") throws -> String {
        try lock.withLock {
            guard let item = index.first(where: { $0.id == ref.id }) else { throw VaultError.notFound(ref.id) }
            let value = try secretValue(item, reason: reason)
            record(item, caller: "you", host: nil, .shown)
            return value
        }
    }

    // MARK: Private

    private func secretValue(_ item: VaultItem, reason: String?) throws -> String {
        guard let data = try backend.read(account: Self.account(item.ref), reason: reason),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { throw VaultError.notFound(item.id) }
        guard stored.binding == item.binding else { throw VaultError.bindingMismatch }
        return stored.value
    }

    private func record(_ item: VaultItem, caller: String, host: String?, _ outcome: VaultActivity.Outcome, reason: String? = nil) {
        log.append(VaultActivity(date: now(), itemID: item.id, label: item.label, caller: caller,
                                 host: host, outcome: outcome, reason: reason))
        if log.count > Self.activityLimit { log.removeFirst(log.count - Self.activityLimit) }
        if let data = try? JSONEncoder().encode(log) {
            try? backend.write(data, account: Self.activityAccount, protection: .deviceUnlocked)
        }
        let publish = { self.objectWillChange.send() }
        if Thread.isMainThread { publish() } else { DispatchQueue.main.async(execute: publish) }
    }

    private func saveIndex() throws {
        try backend.write(try JSONEncoder().encode(index), account: Self.indexAccount, protection: .deviceUnlocked)
    }

    private static func account(_ ref: SecretRef) -> String { "item." + ref.id }
    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Moves keys saved by earlier builds (plain `KeychainStore` entries) into
    /// the vault with their bindings, then removes the old entries.
    private func migrateLegacyKeys() {
        for known in KnownSecret.all where !contains(known.ref) {
            guard let legacy = KeychainStore.shared.string(forKey: known.ref.id), !legacy.isEmpty else { continue }
            if (try? known.store(legacy, in: self)) != nil { KeychainStore.shared.remove(forKey: known.ref.id) }
        }
    }
}

// MARK: - Well-known secrets

/// The secrets Anu ships knowing how to use, with their bindings.
struct KnownSecret: Sendable {
    let ref: SecretRef
    let kind: VaultItemKind
    let label: String
    let service: String
    let hosts: [String]
    let users: [String]

    static let gemini = KnownSecret(
        ref: .gemini, kind: .apiKey, label: "Gemini API key", service: "Gemini",
        hosts: ["generativelanguage.googleapis.com"], users: [VaultCaller.gemini])
    static let braveSearch = KnownSecret(
        ref: .braveSearch, kind: .apiKey, label: "Brave Search key", service: "Brave Search",
        hosts: ["api.search.brave.com"], users: [VaultCaller.webSearch])
    static let all = [gemini, braveSearch]

    @discardableResult
    func store(_ value: String, in vault: Vault = .shared) throws -> VaultItem? {
        try vault.store(value, ref: ref, kind: kind, label: label, service: service,
                        boundHosts: hosts, allowedUsers: users)
    }
}

// MARK: - Redirects

/// Refuses every redirect. Vault-authorized requests are sent with this so a
/// custom header such as `x-goog-api-key` is never forwarded to wherever a
/// redirect points (URLSession only strips `Authorization` across hosts).
final class VaultNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = VaultNoRedirects()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
