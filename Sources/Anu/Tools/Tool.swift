import Foundation

// MARK: - Tool Protocol

protocol Tool: Sendable {
    /// Unique identifier for this tool
    var name: String { get }
    /// Human-readable description for the model
    var description: String { get }
    /// JSON Schema describing the tool's parameters (nil = no parameters)
    var parameters: JSONSchema? { get }
    /// Whether running this tool reaches outside the device (network writes,
    /// launching other apps). Drives the connector capability gate.
    var sideEffect: ToolSideEffect { get }

    // The broker's questions. Tools answer them from the validated payload;
    // they never decide whether they run — `ToolBroker` does.

    /// How much this call can affect the world. Can depend on the input.
    func risk(for arguments: JSONValue) -> RiskTier
    /// One sentence saying exactly what this call will do, written by the tool
    /// — never the model's words. Shown on the approval sheet, in the receipt
    /// under the answer, and in Activity.
    func describe(_ arguments: JSONValue) -> String
    /// The third-party host this call sends its input to (a search API, an MCP
    /// server), or nil when it stays on the phone. Once a run is tainted, even
    /// a read that sends data away needs approval.
    func sendsTo(_ arguments: JSONValue) -> String?
    /// Whether results can contain text written by others (web pages, invites,
    /// shared lists, remote tools). Reading it taints the run (P4).
    func returnsUntrustedContent(for arguments: JSONValue) -> Bool
    /// Fields the user may change on the approval sheet.
    var editableFields: [EditableField] { get }
    /// Wording for why a write needs approval, when the generic reason would
    /// mislead ("Other people will see this" for opening Maps). Wording only:
    /// whether to ask is still the broker's call.
    func approvalNote(for arguments: JSONValue) -> String?

    /// Execute the tool with the given arguments
    func execute(arguments: JSONValue) async throws -> String
    /// How long the broker waits for `execute` before calling it failed.
    var timeout: Duration { get }
    /// The tool's own checks on schema-valid arguments, run by the broker
    /// before any approval (and again on the user's edits), so a call that
    /// can't run is refused instead of being shown for approval first.
    func validate(_ arguments: JSONValue) throws
}

extension Tool {
    /// Most tools finish in seconds; a hung one mustn't stall the loop.
    var timeout: Duration { ToolBroker.toolTimeout }
    /// Most tools have nothing to check beyond their schema.
    func validate(_ arguments: JSONValue) throws {}
    /// Most tools are read-only / on-device; connectors override this.
    var sideEffect: ToolSideEffect { .readOnly }
    func risk(for arguments: JSONValue) -> RiskTier { .read }
    func describe(_ arguments: JSONValue) -> String { ToolDescribing.generic(name, arguments) }
    func sendsTo(_ arguments: JSONValue) -> String? { nil }
    func returnsUntrustedContent(for arguments: JSONValue) -> Bool { false }
    var editableFields: [EditableField] { [] }
    func approvalNote(for arguments: JSONValue) -> String? { nil }
}

/// Shared wording helpers for `Tool.describe`.
enum ToolDescribing {
    /// "calculator: expression 2+2" — for tools with nothing better to say.
    static func generic(_ name: String, _ arguments: JSONValue) -> String {
        guard let object = arguments.objectValue, !object.isEmpty else { return name }
        let parts = object.keys.sorted().compactMap { key -> String? in
            guard let value = object[key], !value.isNull else { return nil }
            return "\(key) \(short(value))"
        }
        return parts.isEmpty ? name : "\(name): " + parts.joined(separator: ", ")
    }

    /// A value as text, cut to `limit` characters.
    static func short(_ value: JSONValue, limit: Int = 80) -> String {
        let text: String
        switch value {
        case .string(let s): text = s
        case .int(let i): text = String(i)
        case .double(let d): text = String(d)
        case .bool(let b): text = b ? "true" : "false"
        case .null: text = ""
        case .array, .object: text = value.canonicalJSON
        }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// `arguments[key]` as trimmed, non-empty text.
    static func text(_ arguments: JSONValue, _ key: String) -> String? {
        guard let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    /// The lowercased `action` argument, which the multi-purpose tools use.
    static func action(_ arguments: JSONValue) -> String {
        (arguments["action"]?.stringValue ?? "").lowercased()
    }

    /// "“text”", cut to `limit` characters.
    static func quoted(_ text: String, limit: Int = 80) -> String {
        "“" + (text.count > limit ? String(text.prefix(limit)) + "…" : text) + "”"
    }
}

/// Classifies a tool by whether it performs an outward-facing action that the
/// user should be able to gate (and always sees in the trace).
enum ToolSideEffect: Sendable, Equatable {
    /// On-device or read-only network (search, calculator, datetime…).
    case readOnly
    /// Reaches an external service or another app (MCP/REST writes, app launch).
    /// Carries the capability key whose Settings toggle controls it.
    case external(capability: ConnectorCapability)
}

/// Which user-facing capability switch governs an `.external` tool.
enum ConnectorCapability: String, Sendable, Equatable {
    /// MCP server tools and REST connectors — consent is "you configured it".
    case connector
    /// Launching other iOS apps / running Shortcuts — gated by a Settings toggle.
    case appLaunch
}

// MARK: - Tool Errors

enum ToolError: LocalizedError {
    case missingArgument(String)
    case invalidArgument(String, expected: String)
    case executionFailed(String)
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name): return "Missing required argument: '\(name)'"
        case .invalidArgument(let name, let expected): return "Invalid argument '\(name)': expected \(expected)"
        case .executionFailed(let reason): return Self.failedPrefix + reason
        case .notImplemented: return "Tool not yet implemented"
        }
    }

    static let failedPrefix = "Tool execution failed: "

    /// A failure as a person reads it: without the "Tool execution failed:"
    /// the model is told (Activity, a Direct answer).
    static func plain(_ message: String) -> String {
        message.hasPrefix(failedPrefix) ? String(message.dropFirst(failedPrefix.count)) : message
    }
}
