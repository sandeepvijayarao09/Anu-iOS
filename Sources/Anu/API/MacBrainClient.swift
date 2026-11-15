import CryptoKit
import Foundation
import Security

// The user's Mac as the top model (Android parity row 18, ADR-113).
//
// Ollama on the user's own Mac answers `/api/chat` over their Wi-Fi. The Mac is
// the user's hardware, but a request to it crosses the network, so it is an
// egress like Gemini's: every request passes the same PII sanitizer and is
// recorded in the Privacy Ledger with the Mac as the destination. Photos and
// other media stay on the phone. Tools are reported, never run (ADR-017).
//
// Two ways to reach it:
//  - plain HTTP straight to Ollama on a local-network address (no secret is
//    ever sent: the vault only attaches secrets over HTTPS);
//  - HTTPS to `Scripts/mac-brain.py`, pinned to its own certificate by SHA-256,
//    with a bearer token the vault holds, bound to the Mac's host.

// MARK: - Vault names

extension SecretRef {
    /// The Mac gateway's bearer token, sent only to the paired Mac's host.
    static let macBrain = SecretRef("mac_brain_token")
}

extension VaultCaller {
    static let macBrain = "mac_brain"
}

// MARK: - Configuration

/// Where the user's Mac answers. Kept in UserDefaults: an address, a model name
/// and a certificate pin are not secrets. The token lives in the vault.
struct MacBrainConfig: Equatable, Sendable {
    static let addressKey = "mac_brain_address"
    static let modelKey = "mac_brain_model"
    static let pinKey = "mac_brain_pin"
    static let defaultPort = 11434
    /// What `mac-brain.py` serves by default; Ollama direct needs a pulled model.
    static let defaultModel = "gemma4:26b"

    let baseURL: URL
    /// The model to ask for. Empty means "the Mac's choice" (the gateway sets it).
    var model: String
    /// SHA-256 of the Mac's certificate (lowercase hex), for `mac-brain.py`.
    var pin: String?

    var host: String { baseURL.host?.lowercased() ?? "" }
    var isHTTPS: Bool { baseURL.scheme?.lowercased() == "https" }
    /// How the Privacy Ledger and the approval sheet name the destination.
    var destination: String {
        if let port = baseURL.port { return "\(host):\(port)" }
        return host
    }

    /// The saved configuration, or nil when no Mac is set up.
    static func load(_ defaults: UserDefaults = .standard) -> MacBrainConfig? {
        guard let raw = defaults.string(forKey: addressKey), !raw.isEmpty,
              let url = URL(string: raw) else { return nil }
        let pin = defaults.string(forKey: pinKey).flatMap { $0.isEmpty ? nil : $0 }
        return MacBrainConfig(baseURL: url, model: defaults.string(forKey: modelKey) ?? "", pin: pin)
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(baseURL.absoluteString, forKey: Self.addressKey)
        defaults.set(model, forKey: Self.modelKey)
        defaults.set(pin ?? "", forKey: Self.pinKey)
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        for key in [addressKey, modelKey, pinKey] { defaults.removeObject(forKey: key) }
    }

    /// Reads "host:port", "host", or a full http(s) URL. Plain HTTP is allowed
    /// only to a local-network address, since it shows the user's words to the
    /// network; HTTPS needs a certificate pin (the Mac signs its own).
    static func parse(address: String, pin: String? = nil, model: String = "") -> MacBrainConfig? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let pin = pin.flatMap { MacPairing.normalizedPin($0) }
        if !text.contains("://") { text = (pin == nil ? "http://" : "https://") + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty else { return nil }
        if scheme == "http", !LocalNetwork.isLocal(host) { return nil }
        if components.port == nil { components.port = defaultPort }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return nil }
        return MacBrainConfig(baseURL: url, model: model, pin: scheme == "https" ? pin : nil)
    }
}

/// `mac-brain.py` prints `anu-mac://<host>:<port>?pin=<sha-256>&token=<token>`.
enum MacPairing {
    struct Code: Equatable {
        let config: MacBrainConfig
        let token: String
    }

    static func parse(_ code: String) -> Code? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("anu-mac://"),
              let components = URLComponents(string: "https://" + trimmed.dropFirst("anu-mac://".count)),
              let host = components.host, !host.isEmpty else { return nil }
        let query = components.queryItems ?? []
        guard let pin = query.first(where: { $0.name == "pin" })?.value.flatMap(normalizedPin),
              let token = query.first(where: { $0.name == "token" })?.value, token.count >= 32 else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        guard let config = MacBrainConfig.parse(address: "https://\(host)\(port)", pin: pin) else { return nil }
        return Code(config: config, token: token)
    }

    /// 64 lowercase hex characters, or nil.
    static func normalizedPin(_ pin: String) -> String? {
        let hex = pin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: ":", with: "")
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }

    /// Stores the token in the vault, bound to the Mac's host and to this client.
    static func storeToken(_ token: String, for config: MacBrainConfig, in vault: Vault = .shared) throws {
        try vault.store(token, ref: .macBrain, kind: .apiKey, label: "Mac token", service: "Your Mac",
                        boundHosts: [config.host], allowedUsers: [VaultCaller.macBrain])
    }
}

/// Which addresses count as the user's own network. Matches what ATS's
/// `NSAllowsLocalNetworking` exempts, plus private IP ranges.
enum LocalNetwork {
    static func isLocal(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host.contains(":") {   // IPv6
            return host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4, host.split(separator: ".").count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
            switch (octets[0], octets[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            case (100, 64...127): return true   // carrier-grade NAT / Tailscale
            default: return false
            }
        }
        // An unqualified name ("studio") resolves on the local network only.
        return !host.contains(".") && !host.isEmpty
    }
}

// MARK: - Wire types

struct OllamaChatMessage: Codable, Equatable, Sendable {
    let role: String
    var content: String
    var toolName: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolName = "tool_name"
    }

    static func system(_ text: String) -> Self { .init(role: "system", content: text) }
    static func user(_ text: String) -> Self { .init(role: "user", content: text) }
    static func assistant(_ text: String) -> Self { .init(role: "assistant", content: text) }
    static func tool(_ name: String, _ text: String) -> Self { .init(role: "tool", content: text, toolName: name) }
}

/// What the Mac's model sent back, piece by piece.
enum MacBrainEvent: Equatable, Sendable {
    case text(String)
    /// The model asked for a tool. Reported, never run here: only the phone's
    /// Tool Broker decides whether anything runs (ADR-017).
    case toolCall(name: String, arguments: JSONValue)
    case done(MacBrainUsage)
}

struct MacBrainUsage: Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    var readMs: Int?
    var writeMs: Int?
    var model: String?
}

enum MacBrainError: LocalizedError, Equatable {
    case notConfigured
    case insecureAddress
    case mediaStaysOnPhone
    case unauthorized
    case http(Int, String)
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No Mac is set up. Add its address in Settings → Your Mac."
        case .insecureAddress: return "Plain HTTP is only allowed to an address on your own network."
        case .mediaStaysOnPhone: return "Photos, voice notes and documents stay on your phone; only text goes to your Mac."
        case .unauthorized: return "Your Mac refused the token. Pair it again in Settings → Your Mac."
        case .http(let code, let message): return "Your Mac answered HTTP \(code)\(message.isEmpty ? "" : ": \(message)")"
        case .server(let message): return "Your Mac said: \(message)"
        case .invalidResponse: return "Your Mac sent something that isn't an Ollama answer."
        }
    }
}

// MARK: - Client

/// Ollama's chat API on the user's Mac. Every chat request is sanitized and
/// ledgered here, so no caller can skip the egress gate.
final class MacBrainClient: @unchecked Sendable {
    let config: MacBrainConfig?
    private let session: URLSession
    private let transport: MacBrainTransport
    private let vault: Vault
    private let ledger: PrivacyLedger?
    /// The ledger is `@MainActor`; tests pass their own, the app the shared one.
    private let useSharedLedger: Bool

    var isConfigured: Bool { config != nil }

    /// - Parameters:
    ///   - session: tests inject a stubbed session; otherwise one is made that
    ///     trusts exactly the pinned certificate.
    ///   - ledger: nil records to `PrivacyLedger.shared`.
    init(config: MacBrainConfig? = MacBrainConfig.load(), session: URLSession? = nil,
         vault: Vault = .shared, ledger: PrivacyLedger? = nil) {
        self.config = config
        self.vault = vault
        self.ledger = ledger
        self.useSharedLedger = ledger == nil
        let transport = MacBrainTransport(host: config?.host ?? "", pin: config?.pin)
        self.transport = transport
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 120
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration, delegate: transport, delegateQueue: nil)
        }
    }

    // MARK: Chat

    /// Streams `/api/chat` (NDJSON). Every message is sanitized before it
    /// leaves, one ledger entry records what went, and `attachments` must be
    /// empty: media never reaches the Mac.
    func stream(
        messages: [OllamaChatMessage],
        tools: [any Tool] = [],
        think: Bool = false,
        attachments: [Data] = [],
        temperature: Double? = nil,
        maxTokens: Int? = nil
    ) -> AsyncThrowingStream<MacBrainEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard attachments.isEmpty else { throw MacBrainError.mediaStaysOnPhone }
                    guard let config = self.config else { throw MacBrainError.notConfigured }

                    var redactions = 0
                    let sanitized = messages.map { message -> OllamaChatMessage in
                        let result = PIISanitizer.sanitize(message.content)
                        redactions += result.redactions
                        var copy = message
                        copy.content = result.text
                        return copy
                    }
                    let body = try Self.chatBody(messages: sanitized, model: config.model, tools: tools,
                                                 think: think, temperature: temperature, maxTokens: maxTokens)
                    let request = try self.request(path: "/api/chat", method: "POST", body: body, config: config)

                    // Recorded just before it goes: the sanitized words, the count.
                    let payload = sanitized.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
                    await self.record(payload: payload, redactions: redactions, config: config)

                    let (bytes, response) = try await self.session.bytes(for: request, delegate: self.transport)
                    guard let http = response as? HTTPURLResponse else { throw MacBrainError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte); if data.count > 600 { break } }
                        throw Self.error(status: http.statusCode, data: data)
                    }
                    var finished = false
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        for event in try Self.events(fromLine: line) {
                            if case .done = event { finished = true }
                            continuation.yield(event)
                        }
                    }
                    if !finished { continuation.yield(.done(MacBrainUsage())) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One answer as text. A tool call from the Mac is never run: the answer
    /// says so instead.
    func generate(prompt: String, system: String? = nil) async throws -> String {
        var messages: [OllamaChatMessage] = []
        if let system { messages.append(.system(system)) }
        messages.append(.user(prompt))
        var text = ""
        var proposed: [String] = []
        for try await event in stream(messages: messages) {
            switch event {
            case .text(let piece): text += piece
            case .toolCall(let name, _): proposed.append(name)
            case .done: break
            }
        }
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.isEmpty, !proposed.isEmpty {
            return "Your Mac asked to use \(proposed.joined(separator: ", ")) instead of answering. Anu runs tools only on your phone, through its own checks, so nothing was run."
        }
        guard !answer.isEmpty else { throw MacBrainError.invalidResponse }
        return answer
    }

    // MARK: Models and health

    /// The models the Mac offers: Ollama's `/api/tags`, or the single model
    /// `mac-brain.py` serves (`/anu/ping`), which answers nothing else.
    func models() async throws -> [String] {
        guard let config else { throw MacBrainError.notConfigured }
        let (data, status) = try await get("/api/tags", config: config)
        if status == 404 || (status == 401 && config.isHTTPS) {
            let ping = try await self.ping(config: config)
            return ping.model.map { [$0] } ?? []
        }
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
        guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let models)? = object["models"] else { throw MacBrainError.invalidResponse }
        return models.compactMap { $0["name"]?.stringValue ?? $0["model"]?.stringValue }.sorted()
    }

    struct Health: Equatable {
        /// "Ollama 0.12.3" or "mac-brain.py · gemma4:26b".
        let summary: String
        let models: [String]
    }

    /// The Test connection button: is it there, and what does it serve?
    func health() async throws -> Health {
        guard let config else { throw MacBrainError.notConfigured }
        let (data, status) = try await get("/api/version", config: config)
        if (200..<300).contains(status),
           case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: data),
           let version = object["version"]?.stringValue {
            return Health(summary: "Ollama \(version)", models: (try? await models()) ?? [])
        }
        if status == 404 || (status == 401 && config.isHTTPS) {
            let ping = try await self.ping(config: config)
            return Health(summary: "mac-brain.py" + (ping.model.map { " · \($0)" } ?? ""),
                          models: ping.model.map { [$0] } ?? [])
        }
        throw Self.error(status: status, data: data)
    }

    private func ping(config: MacBrainConfig) async throws -> (model: String?, context: Int?) {
        let (data, status) = try await get("/anu/ping", config: config)
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
        guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw MacBrainError.invalidResponse
        }
        return (object["model"]?.stringValue, object["context"]?.intValue)
    }

    private func get(_ path: String, config: MacBrainConfig) async throws -> (Data, Int) {
        let request = try self.request(path: path, method: "GET", body: nil, config: config)
        // Even a status check leaves the phone: it's in the ledger, with no content.
        await record(payload: "GET \(path)", redactions: 0, config: config)
        let (data, response) = try await session.data(for: request, delegate: transport)
        guard let http = response as? HTTPURLResponse else { throw MacBrainError.invalidResponse }
        return (data, http.statusCode)
    }

    // MARK: Request building

    /// HTTPS gets the vault's token when one is stored for this Mac; plain HTTP
    /// (a LAN address, straight to Ollama) never carries a secret, and the vault
    /// would refuse one anyway.
    private func request(path: String, method: String, body: Data?, config: MacBrainConfig) throws -> URLRequest {
        if !config.isHTTPS, !LocalNetwork.isLocal(config.host) { throw MacBrainError.insecureAddress }
        guard let url = URL(string: path, relativeTo: config.baseURL)?.absoluteURL else {
            throw MacBrainError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = method == "GET" ? 8 : 120
        if config.isHTTPS, vault.contains(.macBrain) {
            request = try vault.authorize(request, use: SecretUse(
                ref: .macBrain, header: "Authorization", caller: VaultCaller.macBrain, scheme: "Bearer"))
        }
        return request
    }

    private func record(payload: String, redactions: Int, config: MacBrainConfig) async {
        let destination = EgressDestination.mac(host: config.destination)
        if useSharedLedger {
            await PrivacyLedger.shared.record(destination: destination, payload: payload, redactions: redactions)
        } else if let ledger {
            await ledger.record(destination: destination, payload: payload, redactions: redactions)
        }
    }

    // MARK: Wire (pure, unit-tested)

    /// Ollama's `/api/chat` body. `think` is always sent: Ollama turns Gemma 4's
    /// thinking on when it's missing, and an answer can go entirely to reasoning.
    static func chatBody(messages: [OllamaChatMessage], model: String, tools: [any Tool], think: Bool,
                         temperature: Double?, maxTokens: Int?) throws -> Data {
        var body: [String: JSONValue] = [
            "stream": .bool(true),
            "think": .bool(think),
            "messages": .array(messages.map { message in
                var object: [String: JSONValue] = ["role": .string(message.role), "content": .string(message.content)]
                if let name = message.toolName { object["tool_name"] = .string(name) }
                return .object(object)
            }),
        ]
        if !model.isEmpty { body["model"] = .string(model) }
        if !tools.isEmpty {
            body["tools"] = .array(try tools.map { tool in
                let parameters: JSONValue
                if let schema = tool.parameters {
                    parameters = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(schema))
                } else {
                    parameters = .object(["type": .string("object"), "properties": .object([:])])
                }
                return .object(["type": .string("function"), "function": .object([
                    "name": .string(tool.name), "description": .string(tool.description), "parameters": parameters,
                ])])
            })
        }
        var options: [String: JSONValue] = [:]
        if let temperature { options["temperature"] = .double(temperature) }
        if let maxTokens { options["num_predict"] = .int(maxTokens) }
        if !options.isEmpty { body["options"] = .object(options) }
        return try JSONEncoder().encode(JSONValue.object(body))
    }

    /// One NDJSON line → events. Reasoning (`message.thinking`) is dropped.
    static func events(fromLine line: String) throws -> [MacBrainEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard case .object(let chunk)? = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
            throw MacBrainError.invalidResponse
        }
        if let error = chunk["error"]?.stringValue { throw MacBrainError.server(String(error.prefix(300))) }
        var events: [MacBrainEvent] = []
        if let message = chunk["message"] {
            if let text = message["content"]?.stringValue, !text.isEmpty { events.append(.text(text)) }
            if case .array(let calls)? = message["tool_calls"] {
                for call in calls {
                    guard let function = call["function"], let name = function["name"]?.stringValue else { continue }
                    var arguments = function["arguments"] ?? .object([:])
                    // Some builds send arguments as a JSON string.
                    if case .string(let raw) = arguments,
                       let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) {
                        arguments = decoded
                    }
                    events.append(.toolCall(name: name, arguments: arguments))
                }
            }
        }
        if chunk["done"]?.boolValue == true {
            events.append(.done(MacBrainUsage(
                inputTokens: chunk["prompt_eval_count"]?.intValue,
                outputTokens: chunk["eval_count"]?.intValue,
                readMs: chunk["prompt_eval_duration"]?.intValue.map { $0 / 1_000_000 },
                writeMs: chunk["eval_duration"]?.intValue.map { $0 / 1_000_000 },
                model: chunk["model"]?.stringValue)))
        }
        return events
    }

    static func error(status: Int, data: Data) -> MacBrainError {
        if status == 401 || status == 403 { return .unauthorized }
        var message = ""
        if case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: data),
           let text = object["error"]?.stringValue {
            message = text
        } else {
            message = String(decoding: data.prefix(200), as: UTF8.self)
        }
        return .http(status, String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)))
    }
}

// MARK: - Transport: redirects refused, the Mac's own certificate pinned

/// Refuses every redirect (a token must never follow one) and, for HTTPS,
/// trusts exactly the paired Mac's certificate by its SHA-256, and only for
/// the paired host. No certificate authority vouches for it: the pin does.
final class MacBrainTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let host: String
    let pin: String?

    init(host: String, pin: String?) {
        self.host = host.lowercased()
        self.pin = pin
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        evaluate(challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        evaluate(challenge)
    }

    private func evaluate(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        guard let pin else { return (.performDefaultHandling, nil) }
        guard challenge.protectionSpace.host.lowercased() == host,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              Self.sha256(SecCertificateCopyData(leaf) as Data) == pin else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
