import XCTest
@testable import GemmaAgent

@MainActor
final class ConnectorManagerTests: XCTestCase {

    func testRefreshBuildsRESTandAppTools() async {
        let rest = RESTConnectorConfig(name: "Cat Facts", baseURL: "https://catfact.ninja",
                                       method: "GET", toolDescription: "cat facts")
        let manager = ConnectorManager(mcpServers: [], restConnectors: [rest],
                                       appConfig: .default, persists: false)
        await manager.refresh()
        let names = Set(manager.allConnectorTools.map(\.name))
        XCTAssertTrue(names.contains("rest__cat_facts"))
        XCTAssertTrue(names.contains("run_shortcut"))
        XCTAssertTrue(names.contains("open_app"))
        // MCP isn't linked into the test target, so no mcp__ tools appear here.
        XCTAssertFalse(names.contains(where: { $0.hasPrefix("mcp__") }))
    }

    func testDisabledRESTConnectorExcluded() async {
        var rest = RESTConnectorConfig(name: "Off", baseURL: "https://off.example.com")
        rest.enabled = false
        let manager = ConnectorManager(mcpServers: [], restConnectors: [rest],
                                       appConfig: .default, persists: false)
        await manager.refresh()
        XCTAssertFalse(manager.allConnectorTools.contains { $0.name == "rest__off" })
    }

    func testCapabilityGate() {
        let manager = ConnectorManager(mcpServers: [], restConnectors: [],
                                       appConfig: AppLauncherConfig(enabled: false, allowedSchemes: []),
                                       persists: false)
        XCTAssertTrue(manager.isEnabled(.connector))
        XCTAssertFalse(manager.isEnabled(.appLaunch))

        manager.setAppConfig(AppLauncherConfig(enabled: true, allowedSchemes: ["maps"]))
        XCTAssertTrue(manager.isEnabled(.appLaunch))
    }
}
