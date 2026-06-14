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
    /// launching other apps). Drives the consent gate in the agent loop.
    var sideEffect: ToolSideEffect { get }
    /// Execute the tool with the given arguments
    func execute(arguments: JSONValue) async throws -> String
}

extension Tool {
    /// Most tools are read-only / on-device; connectors override this.
    var sideEffect: ToolSideEffect { .readOnly }
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
        case .executionFailed(let reason): return "Tool execution failed: \(reason)"
        case .notImplemented: return "Tool not yet implemented"
        }
    }
}
