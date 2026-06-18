import Foundation

/// Streams from the private compute server behind the `LocalLanguageModel`
/// protocol. Plays two roles: a selectable backend (Settings → Model) and the
/// escalation target. Modeled on `LiteRTGemmaModel`'s streaming contract
/// (`Task.isCancelled` + `continuation.onTermination`).
///
/// ⚠️ When selected as the *default* model, every prompt leaves the device — the
/// privacy ledger records this honestly and the Settings copy says so.
actor PrivateCloudModel: LocalLanguageModel {
    nonisolated let modelName = "Private Compute"

    private let client: PrivateComputeClient
    private var sessionId: String

    init(client: PrivateComputeClient = PrivateComputeClient(),
         sessionId: String = UUID().uuidString) {
        self.client = client
        self.sessionId = sessionId
    }

    func load() async throws {
        do {
            try await client.preflight()
        } catch let error as PrivateComputeError {
            throw ModelError.modelLoadFailed(error.localizedDescription)
        }
    }

    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String> {
        let client = self.client
        let sessionId = self.sessionId
        return AsyncStream<String> { continuation in
            let producer = Task {
                do {
                    for try await token in client.stream(prompt: prompt, sessionId: sessionId, config: config) {
                        if Task.isCancelled { break }
                        continuation.yield(token)
                    }
                } catch {
                    continuation.yield("\n[Private compute error: \(error.localizedDescription)]")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// Rotating the session id starts a fresh server-side ephemeral context —
    /// called on sandbox switch so one chat's context can't bleed into another.
    func resetSession() async {
        await client.resetSession(sessionId)
        sessionId = UUID().uuidString
    }
}
