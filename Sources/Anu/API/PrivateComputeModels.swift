import Foundation

// MARK: - Request models

/// Sampling knobs sent to the private server, mapped 1:1 from `GenerationConfig`.
struct PCSSampling: Encodable {
    let maxTokens: Int
    let temperature: Double
    let topP: Double
    let topK: Int
    let repetitionPenalty: Double
    let stop: [String]

    init(_ config: GenerationConfig) {
        self.maxTokens = config.maxNewTokens
        self.temperature = Double(config.temperature)
        self.topP = Double(config.topP)
        self.topK = config.topK
        self.repetitionPenalty = Double(config.repetitionPenalty)
        self.stop = config.stopSequences
    }
}

/// `POST {endpoint}/v1/generate`
struct PCSRequest: Encodable {
    let prompt: String
    /// Per-sandbox key so the server can hold *ephemeral* context for this
    /// session's lifetime, then discard it (nothing persisted).
    let sessionId: String
    let sampling: PCSSampling
    let stream: Bool
}

/// `POST {endpoint}/v1/session/reset`
struct PCSResetRequest: Encodable {
    let sessionId: String
}

// MARK: - Response models

struct PCSResponse: Decodable {
    let text: String?
    let error: PCSAPIError?
}

/// One SSE chunk: `data: {"delta":"…"}` … terminated by `data: [DONE]`.
struct PCSStreamChunk: Decodable {
    let delta: String?
    let done: Bool?
    let error: PCSAPIError?
}

struct PCSAPIError: Decodable {
    let code: Int
    let message: String
}

// MARK: - Errors

enum PrivateComputeError: LocalizedError {
    case notConfigured
    case unauthorized
    case rateLimited
    case attestationFailed(String)
    case serverError(Int, String)
    case invalidResponse
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No private compute server is configured. Add an endpoint in Settings → Private Compute."
        case .unauthorized:
            return "The private compute server rejected this device (401)."
        case .rateLimited:
            return "The private compute server is rate-limiting requests (429)."
        case .attestationFailed(let why):
            return "Device attestation failed: \(why)"
        case .serverError(let code, let message):
            return "Private compute server error \(code): \(message)"
        case .invalidResponse:
            return "Invalid response from the private compute server."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}
