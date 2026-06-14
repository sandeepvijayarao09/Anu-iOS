import XCTest
@testable import GemmaAgent

private final class FakeOpener: URLOpening, @unchecked Sendable {
    var opened: [URL] = []
    var result = true
    func open(_ url: URL) async -> Bool { opened.append(url); return result }
}

final class AppLauncherToolTests: XCTestCase {

    private let allowAll = AppLauncherConfig(enabled: true, allowedSchemes: ["shortcuts", "maps", "tel"])

    // MARK: Shortcuts

    func testRunShortcutBuildsURL() async throws {
        let opener = FakeOpener()
        let tool = ShortcutsTool(appConfig: allowAll, opener: opener)
        let out = try await tool.execute(arguments: .object([
            "name": .string("My Shortcut"), "input": .string("hello"),
        ]))
        XCTAssertEqual(opener.opened.count, 1)
        let url = opener.opened.first!.absoluteString
        XCTAssertTrue(url.hasPrefix("shortcuts://run-shortcut"), url)
        XCTAssertTrue(url.contains("name=My%20Shortcut"), url)
        XCTAssertTrue(url.contains("text=hello"), url)
        XCTAssertTrue(out.contains("My Shortcut"))
    }

    func testRunShortcutMissingNameThrows() async {
        let tool = ShortcutsTool(appConfig: allowAll, opener: FakeOpener())
        do { _ = try await tool.execute(arguments: .object([:])); XCTFail("expected throw") }
        catch { /* expected */ }
    }

    func testRunShortcutBlockedWhenSchemeNotAllowed() async throws {
        let opener = FakeOpener()
        let tool = ShortcutsTool(appConfig: AppLauncherConfig(enabled: true, allowedSchemes: []), opener: opener)
        let out = try await tool.execute(arguments: .object(["name": .string("X")]))
        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertTrue(out.lowercased().contains("allowed list"))
    }

    // MARK: Open app / URL

    func testOpenAppOpensAllowedScheme() async throws {
        let opener = FakeOpener()
        let tool = OpenAppTool(appConfig: allowAll, opener: opener)
        let out = try await tool.execute(arguments: .object(["url": .string("maps://?q=coffee")]))
        XCTAssertEqual(opener.opened.first?.absoluteString, "maps://?q=coffee")
        XCTAssertTrue(out.contains("Opened"))
    }

    func testOpenAppBlocksDisallowedScheme() async throws {
        let opener = FakeOpener()
        let tool = OpenAppTool(appConfig: allowAll, opener: opener)
        let out = try await tool.execute(arguments: .object(["url": .string("spotify://album/1")]))
        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertTrue(out.contains("spotify"))
    }

    func testOpenAppInvalidURLThrows() async {
        let tool = OpenAppTool(appConfig: allowAll, opener: FakeOpener())
        do { _ = try await tool.execute(arguments: .object(["url": .string("no-scheme-here")]))
            XCTFail("expected throw")
        } catch { /* expected */ }
    }

    func testSideEffectIsAppLaunch() {
        XCTAssertEqual(ShortcutsTool(appConfig: allowAll, opener: FakeOpener()).sideEffect,
                       .external(capability: .appLaunch))
        XCTAssertEqual(OpenAppTool(appConfig: allowAll, opener: FakeOpener()).sideEffect,
                       .external(capability: .appLaunch))
    }
}
