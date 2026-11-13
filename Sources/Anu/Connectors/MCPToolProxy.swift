import Foundation

// MARK: - MCP tool bridging (SDK-agnostic — always compiled)

/// A tool discovered on an MCP server, expressed entirely in our own types so
/// nothing here depends on the MCP SDK (keeps it out of the test target).
struct MCPToolInfo: Sendable {
    let name: String              // raw MCP tool name
    let description: String
    let parameters: JSONSchema?
}

/// Anything that can invoke an MCP tool by its raw name. The real implementation
/// is `MCPConnection` (behind `#if canImport(MCP)`); tests use a fake.
protocol MCPToolInvoking: Sendable {
    func callTool(rawName: String, arguments: JSONValue) async throws -> String
}

/// Adapts a remote MCP tool to the app's `Tool` protocol. Namespaced
/// `mcp__<server>__<tool>` so it never collides with built-ins or other servers.
struct MCPToolProxy: Tool {
    let name: String
    let description: String
    let parameters: JSONSchema?
    var sideEffect: ToolSideEffect { .external(capability: .connector) }

    private let rawName: String
    private let serverSlug: String
    private let serverHost: String
    private let invoker: any MCPToolInvoking

    init(serverSlug: String, serverHost: String, info: MCPToolInfo, invoker: any MCPToolInvoking) {
        self.name = "mcp__\(serverSlug)__\(info.name)"
        self.description = info.description
        self.parameters = info.parameters
        self.rawName = info.name
        self.serverSlug = serverSlug
        self.serverHost = serverHost
        self.invoker = invoker
    }

    func execute(arguments: JSONValue) async throws -> String {
        // Log the egress to the remote MCP server (this is the SDK-agnostic,
        // always-compiled chokepoint — the `#if canImport(MCP)` connection sits
        // behind it). MCP arguments are not PII-sanitized, so redactions = 0.
        await PrivacyLedger.shared.record(
            destination: .mcpServer(name: serverSlug, host: serverHost),
            payload: "\(rawName) \(Self.argsPreview(arguments))",
            redactions: 0
        )
        return try await invoker.callTool(rawName: rawName, arguments: arguments)
    }

    /// Compact JSON rendering of the call arguments for the ledger preview.
    private static func argsPreview(_ args: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(args),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

// MARK: - JSON-Schema conversion (testable with plain JSONValue)

/// Best-effort conversion of a JSON-Schema document (as a `JSONValue`) into the
/// app's `JSONSchema`. Used to turn an MCP tool's `inputSchema` into parameters
/// the prompt builder understands. Unknown constructs degrade to `string`.
enum MCPSchema {
    static func schema(from value: JSONValue) -> JSONSchema? {
        guard case let .object(obj) = value else { return nil }
        return build(obj)
    }

    private static func build(_ obj: [String: JSONValue]) -> JSONSchema {
        let desc = obj["description"]?.stringValue
        let type: String
        if let declared = obj["type"]?.stringValue {
            type = declared
        } else if obj["properties"] != nil {
            type = "object"
        } else {
            // No single type (anyOf / oneOf / a list of types): the prompt says
            // "string", but argument checking passes the value through.
            return .untyped(description: desc)
        }

        switch type {
        case "object":
            var props: [String: JSONSchema] = [:]
            if case let .object(p)? = obj["properties"] {
                for (key, val) in p {
                    if case let .object(sub) = val { props[key] = build(sub) }
                }
            }
            let required = (obj["required"]?.arrayValue ?? []).compactMap { $0.stringValue }
            return .object(description: desc, properties: props,
                           required: required.isEmpty ? nil : required)
        case "array":
            let items: JSONSchema
            if case let .object(it)? = obj["items"] { items = build(it) } else { items = .untyped() }
            return .array(items: items, description: desc)
        case "integer":
            return .integer(description: desc)
        case "number":
            return .number(description: desc)
        case "boolean":
            return .boolean(description: desc)
        case "string":
            let enumVals = obj["enum"]?.arrayValue?.compactMap { $0.stringValue }
            return .string(description: desc, enumValues: (enumVals?.isEmpty == false) ? enumVals : nil)
        default:
            // anyOf / oneOf / unknown → the safest type the prompt can express,
            // marked so argument checking doesn't reject what the server allows.
            return .untyped(description: desc)
        }
    }
}

// MARK: - Broker policy

extension MCPToolProxy {
    /// A remote tool's effects are opaque (the server's annotations aren't read
    /// yet), so every call is treated as leaving Anu and asks first.
    func risk(for arguments: JSONValue) -> RiskTier { .writeExternal }
    func describe(_ arguments: JSONValue) -> String {
        let args = ToolDescribing.generic(rawName, arguments)
        return "Use \(args) on \(serverSlug)"
    }
    func sendsTo(_ arguments: JSONValue) -> String? { serverHost }
    /// The server's reply is written by whoever runs it.
    func returnsUntrustedContent(for arguments: JSONValue) -> Bool { true }
    /// Top-level free-text fields, so the user can fix a note before it's sent.
    /// Fixed choices stay out.
    var editableFields: [EditableField] {
        guard let properties = parameters?.properties else { return [] }
        let required = Set(parameters?.required ?? [])
        return properties.keys.sorted().compactMap { key in
            guard let property = properties[key], property.type == .string, property.enumValues == nil else { return nil }
            let label = key.replacingOccurrences(of: "_", with: " ").capitalized
            return EditableField(key: key, label: label, kind: .text, optional: !required.contains(key))
        }
    }
}
