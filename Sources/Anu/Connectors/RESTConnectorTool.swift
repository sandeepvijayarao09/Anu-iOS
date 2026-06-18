import Foundation

/// Exposes one user-configured REST endpoint to the agent. The host is fixed by
/// the connector's `baseURL`; the agent may only supply a `path`, `query`, and
/// (for write methods) a JSON `body`, so it can't redirect to another host.
struct RESTConnectorTool: Tool {
    let config: RESTConnectorConfig
    private let session: URLSession

    init(config: RESTConnectorConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    var name: String { "rest__\(config.slug)" }

    var description: String {
        let base = config.toolDescription.isEmpty
            ? "Calls the \(config.name) API (\(config.method) \(config.baseURL))."
            : config.toolDescription
        let writeHint = config.isWrite ? " Provide a JSON 'body' for the request." : ""
        return base + " Optionally pass 'path' (appended to the base URL) and 'query' parameters." + writeHint
    }

    var parameters: JSONSchema? {
        var props: [String: JSONSchema] = [
            "path": .string(description: "Path appended to the base URL, e.g. '/v1/items/42'"),
            "query": .object(description: "Query parameters as key/value pairs", properties: [:]),
        ]
        if config.isWrite {
            props["body"] = .object(description: "JSON request body", properties: [:])
        }
        return .object(description: "REST request parameters", properties: props)
    }

    var sideEffect: ToolSideEffect { .external(capability: .connector) }
    // Reads (GET/HEAD) run freely; writes ask for confirmation each time.
    var requiresConfirmation: Bool { config.isWrite }

    func execute(arguments: JSONValue) async throws -> String {
        guard var components = URLComponents(string: config.baseURL) else {
            throw ToolError.executionFailed("Invalid base URL: \(config.baseURL)")
        }

        // Append path (path component only — can't change scheme/host).
        if let path = arguments["path"]?.stringValue, !path.isEmpty {
            components.path = Self.joinPaths(components.path, path)
        }

        // Merge query parameters.
        if case let .object(query)? = arguments["query"], !query.isEmpty {
            var items = components.queryItems ?? []
            for (key, value) in query {
                items.append(URLQueryItem(name: key, value: Self.scalarString(value)))
            }
            components.queryItems = items
        }

        guard let url = components.url else {
            throw ToolError.executionFailed("Could not build a request URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = config.method
        if let name = config.authHeaderName, let value = config.authHeaderValue,
           !name.isEmpty, !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if config.isWrite, let body = arguments["body"], !body.isNull {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(body)
        }

        // Log the egress to the configured REST host before sending.
        let bodyNote = (request.httpBody?.count).map { " · \($0)-byte body" } ?? ""
        await PrivacyLedger.shared.record(
            destination: .restHost(name: config.name, host: url.host ?? config.baseURL),
            payload: "\(config.method) \(url.path)\(url.query.map { "?\($0)" } ?? "")\(bodyNote)",
            redactions: 0
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ToolError.executionFailed("No HTTP response from \(config.name)")
        }
        let text = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
        let clipped = text.count > 4000 ? String(text.prefix(4000)) + "…[truncated]" : text
        guard (200..<300).contains(http.statusCode) else {
            return "HTTP \(http.statusCode) from \(config.name):\n\(clipped)"
        }
        return clipped
    }

    // MARK: - Helpers

    private static func joinPaths(_ base: String, _ added: String) -> String {
        let b = base.hasSuffix("/") ? String(base.dropLast()) : base
        let a = added.hasPrefix("/") ? added : "/" + added
        return b + a
    }

    /// Renders a JSON scalar as a query-string value.
    private static func scalarString(_ value: JSONValue) -> String {
        if let s = value.stringValue { return s }
        if let i = value.intValue { return String(i) }
        if let d = value.doubleValue { return String(d) }
        if let b = value.boolValue { return b ? "true" : "false" }
        return ""
    }
}
