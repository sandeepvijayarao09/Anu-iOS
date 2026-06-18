import Foundation

// MARK: - Tool Registry

@MainActor
final class ToolRegistry {
    private var tools: [String: any Tool] = [:]
    /// Exact set of tool names last installed by `replaceConnectorTools`, so a
    /// later refresh removes precisely those (never a built-in that happens to
    /// share a prefix).
    private var connectorToolNames: Set<String> = []

    func register(_ tool: any Tool) {
        tools[tool.name] = tool
    }

    func unregister(name: String) {
        tools[name] = nil
    }

    func tool(named name: String) -> (any Tool)? {
        tools[name]
    }

    var allTools: [any Tool] {
        Array(tools.values).sorted { $0.name < $1.name }
    }

    var toolNames: [String] {
        Array(tools.keys).sorted()
    }

    /// Swaps the set of connector-provided tools: removes exactly the ones
    /// installed by the previous call, then registers the new set — skipping
    /// any name already owned by a built-in tool (built-ins always win).
    func replaceConnectorTools(_ connectorTools: [any Tool]) {
        for name in connectorToolNames { tools[name] = nil }

        // After removal, any remaining entry at a given name is a built-in, so
        // a collision means a built-in wins and we skip the connector tool.
        var installed: Set<String> = []
        for tool in connectorTools where tools[tool.name] == nil {
            tools[tool.name] = tool
            installed.insert(tool.name)
        }
        connectorToolNames = installed
    }
}
