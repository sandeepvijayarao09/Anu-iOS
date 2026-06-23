import XCTest
@testable import Anu

private struct StubTool: Tool {
    let name: String
    var description = "stub"
    var parameters: JSONSchema?
    func execute(arguments: JSONValue) async throws -> String { "ok" }
}

@MainActor
final class ToolRegistryTests: XCTestCase {

    func testReplaceConnectorToolsAddsThenSwaps() {
        let registry = ToolRegistry()
        registry.register(StubTool(name: "calculator"))   // built-in

        registry.replaceConnectorTools([StubTool(name: "mcp__a__x"), StubTool(name: "rest__y")])
        XCTAssertNotNil(registry.tool(named: "mcp__a__x"))
        XCTAssertNotNil(registry.tool(named: "rest__y"))

        // A later refresh removes exactly the old connector set and installs the new.
        registry.replaceConnectorTools([StubTool(name: "mcp__a__z")])
        XCTAssertNil(registry.tool(named: "mcp__a__x"))
        XCTAssertNil(registry.tool(named: "rest__y"))
        XCTAssertNotNil(registry.tool(named: "mcp__a__z"))
        XCTAssertNotNil(registry.tool(named: "calculator"), "built-in must survive")
    }

    func testConnectorCannotShadowBuiltinAndEmptyReplaceKeepsBuiltins() {
        let registry = ToolRegistry()
        registry.register(StubTool(name: "calculator"))

        registry.replaceConnectorTools([StubTool(name: "calculator")]) // name collision
        XCTAssertNotNil(registry.tool(named: "calculator"))

        registry.replaceConnectorTools([]) // must not remove the built-in
        XCTAssertNotNil(registry.tool(named: "calculator"))
    }

    func testUnregister() {
        let registry = ToolRegistry()
        registry.register(StubTool(name: "foo"))
        XCTAssertNotNil(registry.tool(named: "foo"))
        registry.unregister(name: "foo")
        XCTAssertNil(registry.tool(named: "foo"))
    }
}
