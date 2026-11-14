import Foundation

// MARK: - Gemini Client

final class GeminiClient: Sendable {
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"
    /// Exposed so the privacy ledger can label the cloud destination without
    /// hardcoding the model name in two places.
    static let modelName = "gemini-2.0-flash"
    private let model = GeminiClient.modelName
    private let session: URLSession
    private let vault: Vault

    /// Whether a Gemini key is in the vault. The key itself never leaves the
    /// vault except as the request header (P3, I1).
    var isConfigured: Bool { vault.contains(.gemini) }

    init(session: URLSession = .shared, vault: Vault = .shared) {
        self.session = session
        self.vault = vault
    }

    // MARK: - Non-streaming generation

    func generate(
        prompt: String,
        config: GeminiGenerationConfig = .default
    ) async throws -> String {
        let request = GeminiRequest(
            contents: [GeminiContent(role: "user", text: prompt)],
            generationConfig: config
        )
        let urlRequest = try makeRequest(method: "generateContent", body: request)

        let (data, response) = try await session.data(for: urlRequest, delegate: NoRedirects.shared)
        try validateResponse(response, data: data)

        let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
        guard let text = geminiResponse.text else {
            if let error = geminiResponse.error {
                throw GeminiError.serverError(error.code, error.message)
            }
            throw GeminiError.invalidResponse
        }
        return text
    }

    // MARK: - Streaming generation

    func stream(
        prompt: String,
        config: GeminiGenerationConfig = .default
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = GeminiRequest(
                        contents: [GeminiContent(role: "user", text: prompt)],
                        generationConfig: config
                    )
                    let urlRequest = try self.makeRequest(
                        method: "streamGenerateContent", query: "alt=sse", body: request)

                    let (asyncBytes, response) = try await self.session.bytes(
                        for: urlRequest, delegate: NoRedirects.shared)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw GeminiError.invalidResponse
                    }
                    try self.validateStatusCode(httpResponse.statusCode, data: nil)

                    let parser = SSEParser()
                    for try await line in asyncBytes.lines {
                        let lineData = (line + "\n").data(using: .utf8) ?? Data()
                        let events = await parser.process(data: lineData)
                        for event in events {
                            if let text = GeminiSSEParser.extractText(from: event) {
                                continuation.yield(text)
                            }
                        }
                    }

                    // Flush any remaining
                    let remaining = await parser.flush()
                    for event in remaining {
                        if let text = GeminiSSEParser.extractText(from: event) {
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

    // MARK: - Multi-turn chat

    func chat(
        messages: [(role: String, text: String)],
        config: GeminiGenerationConfig = .default
    ) async throws -> String {
        let contents = messages.map { GeminiContent(role: $0.role, text: $0.text) }
        let request = GeminiRequest(contents: contents, generationConfig: config)
        let urlRequest = try makeRequest(method: "generateContent", body: request)

        let (data, response) = try await session.data(for: urlRequest, delegate: NoRedirects.shared)
        try validateResponse(response, data: data)

        let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
        guard let text = geminiResponse.text else {
            if let error = geminiResponse.error {
                throw GeminiError.serverError(error.code, error.message)
            }
            throw GeminiError.invalidResponse
        }
        return text
    }

    // MARK: - Private helpers

    /// The key goes in the `x-goog-api-key` header, never the URL: URLs end up
    /// in logs, crash reports and proxies. The vault attaches it only for the
    /// bound host. Requests are sent with redirects refused, because URLSession
    /// forwards custom headers such as this one to wherever a redirect points.
    private func makeRequest(method: String, query: String? = nil, body: GeminiRequest) throws -> URLRequest {
        guard isConfigured else { throw GeminiError.noAPIKey }
        var urlString = "\(baseURL)/\(model):\(method)"
        if let query { urlString += "?\(query)" }
        guard let url = URL(string: urlString) else { throw GeminiError.invalidResponse }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return try vault.authorize(urlRequest, use: SecretUse(ref: .gemini, header: "x-goog-api-key", caller: VaultCaller.gemini))
    }

    /// Refuses every redirect for the task it's attached to (see `makeRequest`).
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        static let shared = NoRedirects()

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }
        try validateStatusCode(httpResponse.statusCode, data: data)
    }

    private func validateStatusCode(_ statusCode: Int, data: Data?) throws {
        switch statusCode {
        case 200...299: return
        case 401: throw GeminiError.unauthorized
        case 429: throw GeminiError.rateLimited
        default:
            var message = "HTTP \(statusCode)"
            if let data = data,
               let response = try? JSONDecoder().decode(GeminiResponse.self, from: data),
               let error = response.error {
                message = error.message
                throw GeminiError.serverError(error.code, error.message)
            }
            throw GeminiError.serverError(statusCode, message)
        }
    }
}
