import XCTest
@testable import Anu

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

// MARK: - Contact-aware call / text / email

private struct FakeResolver: ContactResolving {
    var matches: [ContactMatch] = []
    func resolve(name: String) async -> [ContactMatch] { matches }
    static func one(phones: [String] = [], emails: [String] = []) -> FakeResolver {
        FakeResolver(matches: [ContactMatch(name: "Test", phones: phones, emails: emails)])
    }
}

final class ContactActionToolTests: XCTestCase {
    private let config = AppLauncherConfig(
        enabled: true, allowedSchemes: ["tel", "sms", "mailto", "facetime", "facetime-audio"])

    private func tool(_ resolver: FakeResolver, _ opener: FakeOpener) -> ContactActionTool {
        ContactActionTool(resolver: resolver, opener: opener, appConfig: config)
    }

    func testCallRawNumberBuildsTelURL() async throws {
        let opener = FakeOpener()
        let out = try await tool(FakeResolver(), opener).execute(arguments: .object([
            "action": .string("call"), "contact": .string("(555) 123-4567"),
        ]))
        XCTAssertEqual(opener.opened.first?.absoluteString, "tel:5551234567")
        XCTAssertTrue(out.contains("Calling"))
    }

    func testFaceTimeVideoAndAudioBuildURLs() async throws {
        let opener = FakeOpener()
        _ = try await tool(FakeResolver.one(phones: ["555-0100"]), opener).execute(arguments: .object([
            "action": .string("facetime"), "contact": .string("Mom"),
        ]))
        XCTAssertEqual(opener.opened.first?.absoluteString, "facetime:5550100")

        let opener2 = FakeOpener()
        let out = try await tool(FakeResolver(), opener2).execute(arguments: .object([
            "action": .string("facetime_audio"), "contact": .string("5551234567"),
        ]))
        XCTAssertEqual(opener2.opened.first?.absoluteString, "facetime-audio:5551234567")
        XCTAssertTrue(out.contains("FaceTiming"))
    }

    func testDefaultAllowlistCoversEverydaySchemes() {
        let d = AppLauncherConfig.default
        for scheme in ["tel", "sms", "mailto", "maps", "music", "facetime", "facetime-audio", "podcasts"] {
            XCTAssertTrue(d.allows(scheme: scheme), "default should allow \(scheme)")
        }
    }

    func testTextResolvesNameAndBuildsSmsWithBody() async throws {
        let opener = FakeOpener()
        let resolver = FakeResolver.one(phones: ["555-0100"])
        let out = try await tool(resolver, opener).execute(arguments: .object([
            "action": .string("text"), "contact": .string("Mom"), "message": .string("on my way"),
        ]))
        let url = opener.opened.first?.absoluteString ?? ""
        XCTAssertTrue(url.hasPrefix("sms:5550100"), url)
        XCTAssertTrue(url.contains("body=on%20my%20way"), url)
        XCTAssertTrue(out.contains("Texting"))
    }

    func testEmailBuildsMailtoWithSubjectAndBody() async throws {
        let opener = FakeOpener()
        let out = try await tool(FakeResolver(), opener).execute(arguments: .object([
            "action": .string("email"), "contact": .string("alex@example.com"),
            "subject": .string("Hi"), "message": .string("the report"),
        ]))
        let url = opener.opened.first?.absoluteString ?? ""
        XCTAssertTrue(url.hasPrefix("mailto:alex@example.com?"), url)
        XCTAssertTrue(url.contains("subject=Hi"), url)
        XCTAssertTrue(url.contains("body=the%20report"), url)
        XCTAssertTrue(out.contains("Emailing"))
    }

    func testUnknownContactReturnsGracefulMessageNoOpen() async throws {
        let opener = FakeOpener()
        let out = try await tool(FakeResolver(matches: []), opener).execute(arguments: .object([
            "action": .string("call"), "contact": .string("Nobody"),
        ]))
        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertTrue(out.lowercased().contains("couldn't find"))
    }

    func testMultipleMatchesAsksToDisambiguate() async throws {
        let opener = FakeOpener()
        let resolver = FakeResolver(matches: [
            ContactMatch(name: "John Smith", phones: ["555-0001"], emails: []),
            ContactMatch(name: "John Doe", phones: ["555-0002"], emails: []),
        ])
        let out = try await tool(resolver, opener).execute(arguments: .object([
            "action": .string("call"), "contact": .string("John"),
        ]))
        XCTAssertTrue(opener.opened.isEmpty, "must not guess between contacts")
        XCTAssertTrue(out.lowercased().contains("multiple"), out)
        XCTAssertTrue(out.contains("John Smith") && out.contains("John Doe"), out)
    }

    func testBlockedWhenSchemeNotAllowed() async throws {
        let opener = FakeOpener()
        let restricted = ContactActionTool(
            resolver: FakeResolver(), opener: opener,
            appConfig: AppLauncherConfig(enabled: true, allowedSchemes: []))
        let out = try await restricted.execute(arguments: .object([
            "action": .string("call"), "contact": .string("5551234567"),
        ]))
        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertTrue(out.lowercased().contains("allowed list"))
    }

    func testAlwaysAsksAndIsAnAppLaunch() {
        let t = tool(FakeResolver(), FakeOpener())
        // Someone else is on the other end, so the broker always asks first.
        XCTAssertEqual(t.risk(for: .object(["action": .string("text")])), .writeExternal)
        XCTAssertEqual(t.sideEffect, .external(capability: .appLaunch))
    }

    func testPhoneNumberHeuristic() {
        XCTAssertTrue(ContactActionTool.looksLikePhoneNumber("(555) 123-4567"))
        XCTAssertTrue(ContactActionTool.looksLikePhoneNumber("+1 555 0100"))
        XCTAssertFalse(ContactActionTool.looksLikePhoneNumber("Mom"))
        XCTAssertFalse(ContactActionTool.looksLikePhoneNumber("alex@example.com"))
    }
}
