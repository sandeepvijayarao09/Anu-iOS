import XCTest
@testable import GemmaAgent

private final class FakeInvoker: MCPToolInvoking, @unchecked Sendable {
    var lastRawName: String?
    var lastArgs: JSONValue?
    let response: String
    init(response: String) { self.response = response }
    func callTool(rawName: String, arguments: JSONValue) async throws -> String {
        lastRawName = rawName
        lastArgs = arguments
        return response
    }
}

final class MCPToolProxyTests: XCTestCase {

    func testProxyNamespacesAndForwards() async throws {
        let invoker = FakeInvoker(response: "result text")
        let proxy = MCPToolProxy(
            serverSlug: "my_server",
            serverHost: "mcp.example.com",
            info: MCPToolInfo(name: "search", description: "Search the docs", parameters: nil),
            invoker: invoker
        )
        XCTAssertEqual(proxy.name, "mcp__my_server__search")
        XCTAssertEqual(proxy.description, "Search the docs")
        XCTAssertEqual(proxy.sideEffect, .external(capability: .connector))

        let out = try await proxy.execute(arguments: .object(["q": .string("hi")]))
        XCTAssertEqual(out, "result text")
        XCTAssertEqual(invoker.lastRawName, "search")
        XCTAssertEqual(invoker.lastArgs?["q"]?.stringValue, "hi")
    }

    // MARK: - Schema conversion

    func testSchemaObjectWithPropertiesAndRequired() {
        let value = JSONValue.object([
            "type": .string("object"),
            "properties": .object([
                "city": .object(["type": .string("string"), "description": .string("City name")]),
                "days": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("city")]),
        ])
        let schema = MCPSchema.schema(from: value)
        XCTAssertEqual(schema?.type, .object)
        XCTAssertEqual(schema?.properties?["city"]?.type, .string)
        XCTAssertEqual(schema?.properties?["days"]?.type, .integer)
        XCTAssertEqual(schema?.required, ["city"])
    }

    func testSchemaArrayAndEnumAndUnknown() {
        let array = MCPSchema.schema(from: .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
        ]))
        XCTAssertEqual(array?.type, .array)
        XCTAssertEqual(array?.items?.type, .string)

        let enumSchema = MCPSchema.schema(from: .object([
            "type": .string("string"),
            "enum": .array([.string("a"), .string("b")]),
        ]))
        XCTAssertEqual(enumSchema?.type, .string)

        // No "type" and no "properties" → safest expressible fallback (string).
        let unknown = MCPSchema.schema(from: .object(["anyOf": .array([])]))
        XCTAssertEqual(unknown?.type, .string)
    }

    func testSchemaNonObjectReturnsNil() {
        XCTAssertNil(MCPSchema.schema(from: .string("not a schema")))
    }
}
