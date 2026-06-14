import Foundation

// MARK: - Gemini Client

final class GeminiClient: Sendable {
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"
    /// Exposed so the privacy ledger can label the cloud destination without
    /// hardcoding the model name in two places.
    static let modelName = "gemini-2.0-flash"
    private let model = GeminiClient.modelName
    private let session: URLSession

    var apiKey: String {
        KeychainStore.shared.string(forKey: "gemini_api_key") ?? ""
    }

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Non-streaming generation

    func generate(
        prompt: String,
        config: GeminiGenerationConfig = .default
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw GeminiError.noAPIKey }

        let urlString = "\(baseURL)/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw GeminiError.invalidResponse
        }

        let request = GeminiRequest(
            contents: [GeminiContent(role: "user", text: prompt)],
            generationConfig: config
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await session.data(for: urlRequest)
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
                    guard !self.apiKey.isEmpty else { throw GeminiError.noAPIKey }

                    let urlString = "\(self.baseURL)/\(self.model):streamGenerateContent?alt=sse&key=\(self.apiKey)"
                    guard let url = URL(string: urlString) else {
                        throw GeminiError.invalidResponse
                    }

                    let request = GeminiRequest(
                        contents: [GeminiContent(role: "user", text: prompt)],
                        generationConfig: config
                    )

                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.httpBody = try JSONEncoder().encode(request)

                    let (asyncBytes, response) = try await self.session.bytes(for: urlRequest)

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
        guard !apiKey.isEmpty else { throw GeminiError.noAPIKey }

        let urlString = "\(baseURL)/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw GeminiError.invalidResponse
        }

        let contents = messages.map { GeminiContent(role: $0.role, text: $0.text) }
        let request = GeminiRequest(contents: contents, generationConfig: config)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await session.data(for: urlRequest)
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
