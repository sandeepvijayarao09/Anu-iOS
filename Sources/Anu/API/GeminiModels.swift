import Foundation

// MARK: - Request Models

struct GeminiRequest: Encodable {
    let contents: [GeminiContent]
    let generationConfig: GeminiGenerationConfig?
    let systemInstruction: GeminiContent?

    init(
        contents: [GeminiContent],
        generationConfig: GeminiGenerationConfig? = nil,
        systemInstruction: GeminiContent? = nil
    ) {
        self.contents = contents
        self.generationConfig = generationConfig
        self.systemInstruction = systemInstruction
    }
}

struct GeminiContent: Codable {
    let role: String
    let parts: [GeminiPart]

    init(role: String, text: String) {
        self.role = role
        self.parts = [GeminiPart(text: text)]
    }
}

struct GeminiPart: Codable {
    let text: String
}

struct GeminiGenerationConfig: Encodable {
    let maxOutputTokens: Int
    let temperature: Double
    let topP: Double
    let topK: Int

    static let `default` = GeminiGenerationConfig(
        maxOutputTokens: 2048,
        temperature: 0.7,
        topP: 0.95,
        topK: 40
    )
}

// MARK: - Response Models

struct GeminiResponse: Decodable {
    let candidates: [GeminiCandidate]?
    let error: GeminiAPIError?

    var text: String? {
        candidates?.first?.content.parts.first?.text
    }
}

struct GeminiCandidate: Decodable {
    let content: GeminiContent
    let finishReason: String?
    let safetyRatings: [GeminiSafetyRating]?
}

struct GeminiSafetyRating: Decodable {
    let category: String
    let probability: String
}

struct GeminiAPIError: Decodable {
    let code: Int
    let message: String
    let status: String
}

// MARK: - Streaming Models

struct GeminiStreamChunk: Decodable {
    let candidates: [GeminiCandidate]?
    let error: GeminiAPIError?

    var deltaText: String? {
        candidates?.first?.content.parts.first?.text
    }
}

// MARK: - Errors

enum GeminiError: LocalizedError {
    case noAPIKey
    case unauthorized
    case rateLimited
    case serverError(Int, String)
    case invalidResponse
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No Gemini API key configured"
        case .unauthorized: return "Invalid Gemini API key (401 Unauthorized)"
        case .rateLimited: return "Gemini API rate limit exceeded (429)"
        case .serverError(let code, let message): return "Gemini API error \(code): \(message)"
        case .invalidResponse: return "Invalid response from Gemini API"
        case .networkError(let error): return "Network error: \(error.localizedDescription)"
        }
    }
}
