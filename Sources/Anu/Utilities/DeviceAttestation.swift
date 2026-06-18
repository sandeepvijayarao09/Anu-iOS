import Foundation
import CryptoKit
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// Headers that authenticate a request to the private compute server. Either an
/// App Attest assertion (real devices) or a dev bearer token (simulator / CI).
struct AttestationHeaders: Sendable {
    var fields: [String: String]
}

/// Anonymous, account-free device identity for the private compute server.
/// Injectable so tests can stub it (App Attest can't run in the simulator).
protocol DeviceAttesting: Sendable {
    /// True only on real hardware with App Attest. The simulator/CI path uses a
    /// dev bearer token instead.
    var isSupported: Bool { get }
    /// One-time: ensure a device key exists. Returns the key id — the anonymous
    /// per-device identity (no account, no PII). Throws on failure.
    @discardableResult
    func ensureAttested() async throws -> String
    /// Per-request headers binding the request body via an App Attest assertion,
    /// or a dev bearer header on unsupported platforms.
    func headers(forBody body: Data) async throws -> AttestationHeaders
}

/// Concrete App Attest implementation. The key id IS the identity: the server
/// binds it to the attested public key on first use, then verifies a per-request
/// assertion over `SHA256(body)`. No email, no login.
final class DeviceAttestation: DeviceAttesting {
    static let shared = DeviceAttestation()

    static let keyIdKey = "pcs_attest_key_id"
    static let attestedFlagKey = "pcs_attested"
    static let devTokenKey = "pcs_dev_token"

    var isSupported: Bool {
        #if canImport(DeviceCheck)
        return DCAppAttestService.shared.isSupported
        #else
        return false
        #endif
    }

    @discardableResult
    func ensureAttested() async throws -> String {
        #if canImport(DeviceCheck)
        let service = DCAppAttestService.shared
        guard service.isSupported else { return "dev" }   // simulator / CI
        if let existing = KeychainStore.shared.string(forKey: Self.keyIdKey) { return existing }
        let keyId = try await service.generateKey()
        KeychainStore.shared.set(keyId, forKey: Self.keyIdKey)
        UserDefaults.standard.set(false, forKey: Self.attestedFlagKey)
        return keyId
        #else
        return "dev"
        #endif
    }

    func headers(forBody body: Data) async throws -> AttestationHeaders {
        #if canImport(DeviceCheck)
        let service = DCAppAttestService.shared
        if service.isSupported {
            let keyId = try await ensureAttested()
            let clientDataHash = Data(SHA256.hash(data: body))
            do {
                // The first request after key creation carries the full
                // attestation object; the server verifies + binds the key once.
                if !UserDefaults.standard.bool(forKey: Self.attestedFlagKey) {
                    let attestation = try await service.attestKey(keyId, clientDataHash: clientDataHash)
                    UserDefaults.standard.set(true, forKey: Self.attestedFlagKey)
                    return AttestationHeaders(fields: [
                        "X-Key-Id": keyId,
                        "X-Device-Attestation": attestation.base64EncodedString(),
                    ])
                }
                let assertion = try await service.generateAssertion(keyId, clientDataHash: clientDataHash)
                return AttestationHeaders(fields: [
                    "X-Key-Id": keyId,
                    "X-Device-Assertion": assertion.base64EncodedString(),
                ])
            } catch {
                throw PrivateComputeError.attestationFailed(error.localizedDescription)
            }
        }
        #endif
        // Simulator / unsupported: dev bearer token so the demo + tests work.
        // The server gates this behind an explicit non-production flag.
        let token = KeychainStore.shared.string(forKey: Self.devTokenKey) ?? ""
        return AttestationHeaders(fields: token.isEmpty ? [:] : ["Authorization": "Bearer \(token)"])
    }
}
