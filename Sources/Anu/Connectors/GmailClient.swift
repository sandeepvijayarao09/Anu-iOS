import Foundation

// The Gmail REST API for the signed-in user (Android parity #10,
// GmailClient.kt). Every request is written to the Privacy Ledger before it's
// sent; tokens come from `GmailSession.authorize` (the vault), never from
// here. A 401 gets one fresh token and one retry.

enum GmailError: Error, Equatable, LocalizedError {
    case http(Int, String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .http(let status, let message): return "Gmail \(status): \(message)"
        case .malformedResponse: return "Gmail's reply couldn't be read."
        }
    }
}

struct GmailClient: Sendable {
    static let defaultBase = URL(string: "https://\(GmailHosts.api)/gmail/v1/users/me/")!

    let session: GmailSession
    var http: URLSession = URLSession(configuration: .ephemeral)
    var base: URL = GmailClient.defaultBase
    var record: GmailEgressRecorder = GmailLedger.shared

    // MARK: API

    func profileEmail() async throws -> String? {
        try await get(path: "profile")["emailAddress"] as? String
    }

    func search(query: String, max: Int) async throws -> [GmailMessageSummary] {
        let list = try await get(path: "messages", query: [
            URLQueryItem(name: "q", value: query), URLQueryItem(name: "maxResults", value: String(max)),
        ])
        let ids = (list["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        var found: [GmailMessageSummary] = []
        for id in ids {
            let message = try await get(path: "messages/\(id)", query: [
                URLQueryItem(name: "format", value: "metadata"),
                URLQueryItem(name: "metadataHeaders", value: "From"),
                URLQueryItem(name: "metadataHeaders", value: "Subject"),
                URLQueryItem(name: "metadataHeaders", value: "Date"),
            ])
            let headers = GmailParsing.headers(message)
            found.append(GmailMessageSummary(
                id: id, threadId: message["threadId"] as? String ?? id,
                from: headers["from"] ?? "", subject: headers["subject"] ?? "", date: headers["date"] ?? "",
                snippet: GmailParsing.decodeEntities(message["snippet"] as? String ?? "")))
        }
        return found
    }

    func thread(id: String) async throws -> GmailThread {
        let json = try await get(path: "threads/\(id)", query: [URLQueryItem(name: "format", value: "full")])
        let messages = (json["messages"] as? [[String: Any]] ?? []).map(GmailParsing.message)
        return GmailThread(id: id, messages: messages)
    }

    /// Returns the new draft's id.
    func createDraft(rawMIME: String, threadId: String?) async throws -> String {
        var message: [String: Any] = ["raw": GmailMIME.base64URL(rawMIME)]
        if let threadId { message["threadId"] = threadId }
        let reply = try await post(path: "drafts", body: ["message": message])
        guard let id = reply["id"] as? String else { throw GmailError.malformedResponse }
        return id
    }

    /// Returns the sent message's id.
    func send(rawMIME: String, threadId: String?) async throws -> String {
        var body: [String: Any] = ["raw": GmailMIME.base64URL(rawMIME)]
        if let threadId { body["threadId"] = threadId }
        let reply = try await post(path: "messages/send", body: body)
        guard let id = reply["id"] as? String else { throw GmailError.malformedResponse }
        return id
    }

    // MARK: Transport

    private func url(_ path: String, _ query: [URLQueryItem]) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        // Gmail search uses "+" literally; encode it so it isn't read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    private func get(path: String, query: [URLQueryItem] = []) async throws -> [String: Any] {
        var request = URLRequest(url: url(path, query))
        request.httpMethod = "GET"
        return try await call(request)
    }

    private func post(path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url(path, []))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await call(request)
    }

    private func call(_ request: URLRequest) async throws -> [String: Any] {
        for attempt in 0..<2 {
            let authorized = try await session.authorize(request, forceRefresh: attempt > 0)
            await record(.restHost(name: "Gmail", host: request.url?.host ?? GmailHosts.api), GmailLedger.describe(request))
            let (data, response) = try await http.data(for: authorized, delegate: VaultNoRedirects.shared)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 { continue }
            guard (200..<300).contains(status) else {
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let message = ((json?["error"] as? [String: Any])?["message"] as? String)
                    ?? String(decoding: data.prefix(300), as: UTF8.self)
                throw GmailError.http(status, message)
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw GmailError.malformedResponse
            }
            return json
        }
        throw GmailError.http(401, "the token was refused twice")
    }
}
