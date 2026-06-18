import Foundation

/// HTTP(S) client for the private compute server. Mirrors `GeminiClient`:
/// injectable `URLSession`, typed errors, streaming + non-streaming. Auth is via
/// App Attest headers (not a URL key); the endpoint is operator-configured and
/// host-fixed per request (like `RESTConnectorTool`). HTTPS only.
final class PrivateComputeClient: Sendable {
    static let modelName = "Private Compute"

    private let session: URLSession
    private let attestation: any DeviceAttesting

    init(session: URLSession = .shared,
         attestation: any DeviceAttesting = DeviceAttestation.shared) {
        self.session = session
        self.attestation = attestation
    }

    var endpoint: String { KeychainStore.shared.string(forKey: "pcs_endpoint") ?? "" }
    var isConfigured: Bool { !endpoint.isEmpty }
    var endpointHost: String { URL(string: endpoint)?.host ?? endpoint }

    /// Validates the endpoint is set and HTTPS. ATS forbids cleartext anyway;
    /// rejecting non-HTTPS here gives a clear error instead of a network failure.
    func validatedBaseURL() throws -> URL {
        guard !endpoint.isEmpty else { throw PrivateComputeError.notConfigured }
        guard let url = URL(string: endpoint), url.scheme?.lowercased() == "https" else {
            throw PrivateComputeError.invalidResponse
        }
        return url
    }

    /// Reachability + attestation check for `load()`.
    func preflight() async throws {
        _ = try validatedBaseURL()
        _ = try await attestation.ensureAttested()
    }

    // MARK: - Non-streaming

    func generate(prompt: String,
                  sessionId: String,
                  config: GenerationConfig,
                  recordsLedger: Bool = true) async throws -> String {
        let base = try validatedBaseURL()
        let body = try JSONEncoder().encode(
            PCSRequest(prompt: prompt, sessionId: sessionId, sampling: PCSSampling(config), stream: false))
        var request = URLRequest(url: base.appendingPathComponent("v1/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await applyAuth(&request, body: body)
        request.httpBody = body

        if recordsLedger { await recordEgress(prompt) }

        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        let decoded = try JSONDecoder().decode(PCSResponse.self, from: data)
        if let text = decoded.text { return text }
        if let error = decoded.error { throw PrivateComputeError.serverError(error.code, error.message) }
        throw PrivateComputeError.invalidResponse
    }

    // MARK: - Streaming

    func stream(prompt: String,
                sessionId: String,
                config: GenerationConfig,
                recordsLedger: Bool = true) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let base = try self.validatedBaseURL()
                    let body = try JSONEncoder().encode(
                        PCSRequest(prompt: prompt, sessionId: sessionId, sampling: PCSSampling(config), stream: true))
                    var request = URLRequest(url: base.appendingPathComponent("v1/generate"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    try await self.applyAuth(&request, body: body)
                    request.httpBody = body

                    if recordsLedger { await self.recordEgress(prompt) }

                    let (asyncBytes, response) = try await self.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw PrivateComputeError.invalidResponse
                    }
                    try Self.validateStatus(http.statusCode)

                    let parser = SSEParser()
                    for try await line in asyncBytes.lines {
                        let lineData = (line + "\n").data(using: .utf8) ?? Data()
                        for event in await parser.process(data: lineData) {
                            if let text = PrivateComputeSSEParser.extractText(from: event) {
                                continuation.yield(text)
                            }
                        }
                    }
                    for event in await parser.flush() {
                        if let text = PrivateComputeSSEParser.extractText(from: event) {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Best-effort: tell the server to drop this session's ephemeral context.
    func resetSession(_ sessionId: String) async {
        guard let base = try? validatedBaseURL(),
              let body = try? JSONEncoder().encode(PCSResetRequest(sessionId: sessionId)) else { return }
        var request = URLRequest(url: base.appendingPathComponent("v1/session/reset"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try? await applyAuth(&request, body: body)
        request.httpBody = body
        _ = try? await session.data(for: request)
    }

    // MARK: - Helpers

    private func applyAuth(_ request: inout URLRequest, body: Data) async throws {
        let headers = try await attestation.headers(forBody: body)
        for (key, value) in headers.fields {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    private func recordEgress(_ prompt: String) async {
        await PrivacyLedger.shared.record(
            destination: .privateComputeServer(endpoint: endpointHost),
            payload: prompt,
            redactions: 0)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw PrivateComputeError.invalidResponse }
        try validateStatus(http.statusCode)
    }

    private static func validateStatus(_ code: Int) throws {
        switch code {
        case 200...299: return
        case 401: throw PrivateComputeError.unauthorized
        case 403: throw PrivateComputeError.attestationFailed("server rejected attestation (403)")
        case 429: throw PrivateComputeError.rateLimited
        default:  throw PrivateComputeError.serverError(code, "HTTP \(code)")
        }
    }
}
