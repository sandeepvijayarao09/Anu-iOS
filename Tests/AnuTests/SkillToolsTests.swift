import XCTest
import os
@testable import Anu

/// The skill tools through the broker: risk tiers, taint, the skill-called-as-
/// a-tool answer, run_intent's approval, and adding a skill from a web address
/// (ADR-120). No real network: downloads go through a URLProtocol stub.
@MainActor
final class SkillToolsTests: XCTestCase {
    private var registry: ToolRegistry!
    private var approvals: ApprovalCenter!
    private var broker: ToolBroker!
    private var asked: [ApprovalRequest] = []
    private var answer: ApprovalDecision = .approved
    private var library: SkillLibrary!
    private let opener = RecordingOpener()

    static let hashSkill = """
    ---
    name: calculate-hash
    description: SHA-256 checksum of text.
    ---
    Call run_js with skill_name calculate-hash and data {"text": "..."}.
    """

    override func setUp() async throws {
        registry = ToolRegistry()
        approvals = ApprovalCenter()
        asked = []
        answer = .approved
        approvals.autoDecide = { [unowned self] request in
            self.asked.append(request)
            return self.answer
        }
        broker = ToolBroker(registry: registry, approvals: approvals, audit: ToolAuditLog(fileURL: nil))
        let bundled = try AgentSkillTests.bundle(["calculate-hash": Self.hashSkill])
        try FileManager.default.createDirectory(at: bundled.appendingPathComponent("calculate-hash/scripts"),
                                                withIntermediateDirectories: true)
        try "function ai_edge_gallery_get_result(d) { return JSON.stringify({result: 'h:' + JSON.parse(d).text}) }"
            .write(to: bundled.appendingPathComponent("calculate-hash/scripts/index.js"), atomically: true, encoding: .utf8)
        library = SkillLibrary(bundledRoot: bundled, addedRoot: AgentSkillTests.tempDir(),
                               defaults: AgentSkillTests.defaults(), keys: AgentSkillTests.keys, recordEgress: { _, _ in })
        registry.register(LoadSkillTool(catalog: library))
        registry.register(RunJSTool(library: library))
        registry.register(RunIntentTool(
            catalog: library,
            config: { AppLauncherConfig(enabled: true, allowedSchemes: ["mailto", "sms", "tel", "maps", "https"]) },
            opener: opener))
        registry.register(PrivateNoteTool())
    }

    private func call(_ name: String, _ args: [String: JSONValue]) -> ToolCallInfo {
        ToolCallInfo(name: name, arguments: .object(args))
    }

    // MARK: Risk tiers

    func testSkillToolsHaveTheRightTiers() {
        let load = LoadSkillTool(catalog: library)
        let js = RunJSTool(library: library)
        let intent = RunIntentTool(catalog: library)
        XCTAssertEqual(load.risk(for: .object([:])), .read)
        XCTAssertEqual(js.risk(for: .object([:])), .read)
        XCTAssertEqual(js.sideEffect, .readOnly)
        XCTAssertEqual(intent.sideEffect, .external(capability: .appLaunch), "behind the app-launch switch")
        let email: JSONValue = .object(["intent": .string("send_email"),
                                        "parameters": .string(#"{"extra_email": "maya@example.com"}"#)])
        XCTAssertEqual(intent.risk(for: email), .writeExternal)
    }

    // MARK: load_skill

    func testLoadSkillReturnsTheWholeSkillMdWithoutAsking() async {
        let run = RunState(turnKey: "t")
        let outcome = await broker.handle(call("load_skill", ["skill_name": .string("Calculate_Hash")]), run: run)
        guard case .ok(let result, let summary, let wrote) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(result.contains("skill_instructions"), result)
        XCTAssertTrue(result.contains("Call run_js with skill_name calculate-hash"), result)
        XCTAssertEqual(summary, "Load the calculate-hash skill")
        XCTAssertFalse(wrote)
        XCTAssertTrue(asked.isEmpty)
        XCTAssertFalse(run.tainted, "a built-in skill is Anu's own words")
    }

    func testLoadingAnAddedSkillTaintsTheRun() async throws {
        try library.add(skillMd: Self.hashSkill.replacingOccurrences(of: "calculate-hash", with: "their-skill"))
        let run = RunState(turnKey: "t")
        _ = await broker.handle(call("load_skill", ["skill_name": .string("their-skill")]), run: run)
        XCTAssertTrue(run.tainted, "an added skill is someone else's words (P4)")

        // So a later private change in the same turn asks first.
        _ = await broker.handle(call("note_to_self", ["contact": .string("x")]), run: run)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.reason, "This request read content written by others")
    }

    func testUnknownSkillNamesTheSkills() async {
        let outcome = await broker.handle(call("load_skill", ["skill_name": .string("nope")]), run: RunState(turnKey: "t"))
        guard case .failed(let reason, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.contains("calculate-hash"), reason)
    }

    func testDescriptionListsOnlyTurnedOnSkills() {
        XCTAssertTrue(LoadSkillTool(catalog: library).description.contains("\"calculate-hash\": SHA-256 checksum of text."))
        library.setEnabled("calculate-hash", false)
        XCTAssertFalse(LoadSkillTool(catalog: library).description.contains("calculate-hash"))
    }

    // MARK: A skill called as a tool

    func testCallingASkillAsAToolSaysToLoadItFirst() async {
        let outcome = await broker.handle(call("calculate-hash", ["text": .string("hi")]), run: RunState(turnKey: "t"))
        XCTAssertEqual(outcome, .invalid(reason:
            "There is no tool named calculate-hash. calculate-hash is a skill: call load_skill with skill_name \"calculate-hash\" first, then follow its instructions."))
        let other = await broker.handle(call("no_such_thing", [:]), run: RunState(turnKey: "t"))
        guard case .invalid(let reason) = other else { return XCTFail() }
        XCTAssertTrue(reason.hasPrefix("There is no tool named no_such_thing. Available:"), reason)
    }

    // MARK: run_js

    func testRunJSRunsOfflineWithoutAskingAndTaints() async {
        let run = RunState(turnKey: "t")
        let outcome = await broker.handle(call("run_js", [
            "skill_name": .string("calculate-hash"),
            "script_name": .string("index.html"),
            "data": .object(["text": .string("abc")]),
        ]), run: run)
        guard case .ok(let result, let summary, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(result, #"{"result":"h:abc"}"#)
        XCTAssertEqual(summary, #"Run the calculate-hash skill with “{"text":"abc"}”"#)
        XCTAssertTrue(asked.isEmpty, "a sandboxed script with no network is a read")
        XCTAssertTrue(run.tainted, "a script's output taints the run (P4)")

        // A later outward action in the same turn asks first, as it always does.
        _ = await broker.handle(call("run_intent", [
            "intent": .string("send_email"),
            "parameters": .string(#"{"extra_email": "maya@example.com", "extra_subject": "Hash"}"#),
        ]), run: run)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.tainted, true, "the sheet asks for a closer read")
    }

    func testRunJSRefusesSkillsThatNeedASecret() async throws {
        try library.add(skillMd: "---\nname: keyed\ndescription: needs a key\nrequire-secret: true\n---\nrun it",
                        scripts: ["index.js": "function run(d) { return 'ran' }"])
        let outcome = await broker.handle(call("run_js", ["skill_name": .string("keyed")]), run: RunState(turnKey: "t"))
        guard case .failed(let reason, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.contains("needs an API key"), reason)
    }

    func testRunJSReadsGallerysAnswerShape() {
        XCTAssertEqual(RunJSTool.read("plain text"), "plain text")
        XCTAssertEqual(RunJSTool.read(#"{"result": "x", "other": 1}"#), #"{"result":"x"}"#)
        XCTAssertTrue(RunJSTool.read(#"{"result": "x", "image": {"base64": "..."}}"#).contains("can't show"))
    }

    // MARK: run_intent

    func testRunIntentAsksWithTheExactPayloadThenOpensMail() async {
        let run = RunState(turnKey: "t")
        let outcome = await broker.handle(call("run_intent", [
            "intent": .string("send_email"),
            "parameters": .string(#"{"extra_email": "maya@example.com", "extra_subject": "Lunch", "extra_text": "Friday?"}"#),
        ]), run: run)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked[0].risk, .writeExternal)
        XCTAssertEqual(asked[0].reason, "This hands off to another app")
        XCTAssertEqual(asked[0].summary, "Open an email to maya@example.com “Lunch” in Mail. Nothing is sent until you tap Send there")
        guard case .ok(_, _, let wrote) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(wrote)
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["mailto:maya@example.com?subject=Lunch&body=Friday?"])
    }

    func testDeclinedIntentOpensNothing() async {
        answer = .denied
        let outcome = await broker.handle(call("run_intent", [
            "intent": .string("send_sms"),
            "parameters": .object(["phone_number": .string("+1 555 0100"), "sms_body": .string("on my way")]),
        ]), run: RunState(turnKey: "t"))
        guard case .rejected(_, _, let code) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(code, .declined)
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testIntentURLsAreBuiltFromCheckedParameters() throws {
        let tool = RunIntentTool(catalog: library)
        func url(_ intent: String, _ params: [String: String]) throws -> String {
            let p = params.map { "\"\($0.key)\": \"\($0.value)\"" }.joined(separator: ",")
            return try tool.url(for: .object(["intent": .string(intent), "parameters": .string("{\(p)}")])).absoluteString
        }
        XCTAssertEqual(try url("send_sms", ["phone_number": "+1 (555) 0100", "sms_body": "hi there"]), "sms:+15550100&body=hi%20there")
        XCTAssertEqual(try url("call_phone", ["phone_number": "555-0100"]), "tel:5550100")
        XCTAssertEqual(try url("open_maps", ["query": "coffee near me"]), "maps://?q=coffee%20near%20me")
        XCTAssertEqual(try url("open_url", ["url": "https://example.com/a"]), "https://example.com/a")
        XCTAssertThrowsError(try url("open_url", ["url": "javascript:alert(1)"]))
        XCTAssertThrowsError(try url("call_phone", ["phone_number": "12;rm"]))
        XCTAssertThrowsError(try url("send_email", [:]))
    }

    func testAnIntentThatIsReallyASkillSaysSoWithoutAsking() async {
        let outcome = await broker.handle(call("run_intent", ["intent": .string("calculate-hash")]), run: RunState(turnKey: "t"))
        guard case .failed(let reason, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.contains("calculate-hash is a skill: call load_skill"), reason)
        XCTAssertTrue(asked.isEmpty, "nothing to approve")
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testSchemeOutsideTheAllowedListIsRefused() async {
        registry.register(RunIntentTool(catalog: library, config: { AppLauncherConfig(enabled: true, allowedSchemes: ["tel"]) },
                                        opener: opener))
        let outcome = await broker.handle(call("run_intent", [
            "intent": .string("open_maps"), "parameters": .string(#"{"query": "park"}"#),
        ]), run: RunState(turnKey: "t"))
        guard case .ok(let result, _, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(result.contains("isn't in the allowed list"), result)
        XCTAssertTrue(opener.opened.isEmpty)
    }

    // MARK: Adding from a web address

    func testAddFromURLDownloadsOnceRecordsEgressAndStores() async throws {
        let skill = """
        ---
        name: web-skill
        description: From the web.
        ---
        Run scripts/index.js with run_js.
        """
        StubServer.set([
            "https://skills.example.com/web-skill/SKILL.md": (200, skill),
            "https://skills.example.com/web-skill/scripts/index.js": (200, "function run(d) { return 'web:' + d }"),
        ])
        let egress = EgressLog()
        let added = AgentSkillTests.tempDir()
        let web = SkillLibrary(bundledRoot: nil, addedRoot: added, defaults: AgentSkillTests.defaults(),
                               keys: AgentSkillTests.keys, session: StubServer.session(),
                               recordEgress: { destination, payload in egress.add(destination, payload) })

        let added1 = try await web.addFromURL("https://skills.example.com/web-skill/")
        XCTAssertEqual(added1.name, "web-skill")
        XCTAssertEqual(added1.source, "https://skills.example.com/web-skill")
        XCTAssertEqual(StubServer.requested, ["https://skills.example.com/web-skill/SKILL.md",
                                              "https://skills.example.com/web-skill/scripts/index.js"])
        XCTAssertEqual(egress.entries.map(\.payload), StubServer.requested, "every download is in the ledger")
        XCTAssertEqual(egress.entries.first?.destination, .restHost(name: "Skill download", host: "skills.example.com"))

        // It runs from the stored copy: no further requests.
        StubServer.set([:])
        registry.register(RunJSTool(library: web))
        let outcome = await broker.handle(call("run_js", ["skill_name": .string("web-skill"), "data": .string("x")]),
                                          run: RunState(turnKey: "t"))
        XCTAssertEqual(outcome, .ok(result: "web:x", summary: "Run the web-skill skill with “x”", wrote: false))
        XCTAssertTrue(StubServer.requested.isEmpty)
    }

    func testMalformedOrMissingWebSkillsAreRefused() async {
        let web = SkillLibrary(bundledRoot: nil, addedRoot: AgentSkillTests.tempDir(), defaults: AgentSkillTests.defaults(),
                               keys: AgentSkillTests.keys, session: StubServer.session(), recordEgress: { _, _ in })
        StubServer.set(["https://x.example.com/a/SKILL.md": (404, "")])
        do { _ = try await web.addFromURL("https://x.example.com/a"); XCTFail() } catch {
            XCTAssertEqual(error.localizedDescription, "couldn't download SKILL.md (HTTP 404)")
        }
        StubServer.set(["https://x.example.com/b/SKILL.md": (200, "<html>not a skill</html>")])
        do { _ = try await web.addFromURL("https://x.example.com/b/SKILL.md"); XCTFail() } catch {
            XCTAssertEqual(error.localizedDescription, "a SKILL.md starts with a --- line")
        }
        XCTAssertEqual(StubServer.requested, ["https://x.example.com/b/SKILL.md"], "nothing more is fetched")
        do { _ = try await web.addFromURL("http://x.example.com/c"); XCTFail() } catch {
            XCTAssertEqual(error.localizedDescription, "a skill's address must start with https://")
        }
        XCTAssertTrue(web.enabledSkills().isEmpty)
    }

    // MARK: In the agent loop

    func testTheLoopRecoversFromASkillCalledAsATool() async throws {
        let model = QueuedMockModel([
            #"{"tool_call": {"name": "word-count", "arguments": {"text": "one two three"}}}"#,
            #"{"tool_call": {"name": "load_skill", "arguments": {"skill_name": "word-count"}}}"#,
            #"{"tool_call": {"name": "run_js", "arguments": {"skill_name": "word-count", "script_name": "index.js", "data": "{\"text\": \"one two three\"}"}}}"#,
            "That text has 3 words.",
        ])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skills-orch-\(UUID().uuidString)")
        let orch = AgentOrchestrator(model: model, sessionsDirectory: dir)
        XCTAssertNotNil(orch.toolRegistry.tool(named: "load_skill"), "the orchestrator registers the skill tools")
        orch.conversationHistory = [.user("How many words in 'one two three'?")]
        let run = RunState(turnKey: "t")
        orch.currentRunState = run
        await orch.reactLoop(startingIteration: 0)

        let results = orch.conversationHistory.filter { $0.role == .toolResult }.map(\.content)
        XCTAssertEqual(results.count, 3, "\(results)")
        XCTAssertTrue(results[0].contains("word-count is a skill: call load_skill"), results[0])
        XCTAssertTrue(results[1].contains("skill_instructions"), results[1])
        XCTAssertTrue(results[2].contains(#""words":3"#), results[2])
        XCTAssertEqual(orch.conversationHistory.last?.content, "That text has 3 words.")
        XCTAssertTrue(run.tainted)
        XCTAssertTrue(model.capturedPrompts[0].contains("\"word-count\":"), "the prompt lists the bundled skills")
    }
}

// MARK: - Test doubles

/// A private write, which asks only once a run is tainted.
private struct PrivateNoteTool: Tool {
    let name = "note_to_self"
    let description = "Saves a note"
    var parameters: JSONSchema? { .object(properties: ["contact": .string()]) }
    func risk(for arguments: JSONValue) -> RiskTier { .writePrivate }
    func execute(arguments: JSONValue) async throws -> String { "saved" }
}

final class RecordingOpener: URLOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var opened: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    func open(_ url: URL) async -> Bool {
        lock.lock(); urls.append(url); lock.unlock()
        return true
    }
}

final class EgressLog: @unchecked Sendable {
    struct Entry { let destination: EgressDestination; let payload: String }
    private let lock = NSLock()
    private var items: [Entry] = []
    var entries: [Entry] { lock.lock(); defer { lock.unlock() }; return items }
    func add(_ destination: EgressDestination, _ payload: String) {
        lock.lock(); items.append(Entry(destination: destination, payload: payload)); lock.unlock()
    }
}

/// Answers requests from a fixed table and records what was asked.
final class StubServer: URLProtocol {
    private static let state = OSAllocatedUnfairLock(initialState: (routes: [String: (Int, String)](), requested: [String]()))

    static func set(_ routes: [String: (Int, String)]) {
        state.withLock { $0 = (routes, []) }
    }

    static var requested: [String] { state.withLock { $0.requested } }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url ?? URL(string: "https://invalid")!
        let route = Self.state.withLock { s -> (Int, String) in
            s.requested.append(url.absoluteString)
            return s.routes[url.absoluteString] ?? (404, "")
        }
        let response = HTTPURLResponse(url: url, statusCode: route.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(route.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
