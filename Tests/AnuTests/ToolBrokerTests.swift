import XCTest
@testable import Anu

/// The Tool Broker's policy (ARCHITECTURE §11): what runs by itself, what asks,
/// and that what runs is exactly what was approved (I2, I6, P4).
@MainActor
final class ToolBrokerTests: XCTestCase {
    private var registry: ToolRegistry!
    private var approvals: ApprovalCenter!
    private var audit: ToolAuditLog!
    private var broker: ToolBroker!
    private var runs: RunRecorder!
    private var asked: [ApprovalRequest] = []
    /// Answers given in order; the last repeats.
    private var answers: [ApprovalDecision] = [.approved]

    override func setUp() async throws {
        registry = ToolRegistry()
        approvals = ApprovalCenter()
        audit = ToolAuditLog(fileURL: nil)
        runs = RunRecorder()
        asked = []
        answers = [.approved]
        approvals.autoDecide = { [unowned self] request in
            self.asked.append(request)
            return self.answers.count > 1 ? self.answers.removeFirst() : self.answers[0]
        }
        broker = ToolBroker(registry: registry, approvals: approvals, audit: audit)
        registry.register(StubTool(name: "look_up", risk: .read, runs: runs))
        registry.register(StubTool(name: "read_web", risk: .read, untrusted: true, runs: runs))
        registry.register(StubTool(name: "search_away", risk: .read, destination: "search.example.com", runs: runs))
        registry.register(StubTool(name: "note_to_self", risk: .writePrivate, runs: runs))
        registry.register(StubTool(name: "send_text", risk: .writeExternal, runs: runs,
                                   editable: [EditableField(key: "message", label: "Message", kind: .text)]))
        registry.register(StubTool(name: "post_remote", risk: .writeExternal, destination: "notes.example.com", runs: runs))
    }

    private func call(_ name: String, _ args: [String: JSONValue] = ["contact": .string("Maya")]) -> ToolCallInfo {
        ToolCallInfo(name: name, arguments: .object(args))
    }

    // MARK: What runs by itself

    func testReadRunsWithoutAsking() async {
        let outcome = await broker.handle(call("look_up"), run: RunState(turnKey: "t"))
        XCTAssertEqual(outcome, .ok(result: "ran look_up", summary: "look_up for Maya", wrote: false))
        XCTAssertTrue(asked.isEmpty)
        XCTAssertEqual(runs.count("look_up"), 1)
    }

    func testPrivateWriteRunsByItselfUntilTheRunIsTainted() async {
        let run = RunState(turnKey: "t")
        _ = await broker.handle(call("note_to_self", ["contact": .string("first")]), run: run)
        XCTAssertTrue(asked.isEmpty, "an untainted private change runs by itself")

        _ = await broker.handle(call("read_web"), run: run)
        XCTAssertTrue(run.tainted, "reading content written by others taints the run")

        _ = await broker.handle(call("note_to_self", ["contact": .string("second")]), run: run)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.reason, "This request read content written by others")
        XCTAssertEqual(asked.first?.tainted, true)
    }

    func testTaintedReadThatSendsDataAwayAsks() async {
        let clean = RunState(turnKey: "a")
        _ = await broker.handle(call("search_away"), run: clean)
        XCTAssertTrue(asked.isEmpty, "a clean run may search without asking")

        let tainted = RunState(turnKey: "b")
        tainted.taint()
        _ = await broker.handle(call("search_away"), run: tainted)
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked[0].reason.contains("search.example.com"), asked[0].reason)
    }

    // MARK: What always asks (I2)

    func testExternalWriteAsksWithTheExactPayload() async {
        let outcome = await broker.handle(
            call("send_text", ["contact": .string("Maya"), "message": .string("On my way"), "junk": .string("x")]),
            run: RunState(turnKey: "t"))
        XCTAssertEqual(asked.count, 1)
        let request = asked[0]
        XCTAssertEqual(request.payload, .object(["contact": .string("Maya"), "message": .string("On my way")]),
                       "undeclared keys are dropped: what's approved is what runs")
        XCTAssertEqual(request.summary, "send_text for Maya", "the tool writes the summary, not the model")
        XCTAssertEqual(request.reason, "Other people will see this")
        XCTAssertEqual(runs.lastArguments("send_text"), request.payload)
        guard case .ok(_, _, let wrote) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(wrote)
    }

    func testExternalWriteToAServiceSaysWhereItGoes() async {
        _ = await broker.handle(call("post_remote"), run: RunState(turnKey: "t"))
        XCTAssertEqual(asked.first?.reason, "This goes to notes.example.com, outside your phone")
        XCTAssertEqual(asked.first?.destination, "notes.example.com")
    }

    func testDeclinedWriteNeverRuns() async {
        answers = [.denied]
        let run = RunState(turnKey: "t")
        let outcome = await broker.handle(call("send_text"), run: run)
        XCTAssertEqual(runs.count("send_text"), 0)
        guard case .rejected(_, _, let code) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(code, .declined)
        XCTAssertTrue(outcome.observation.contains("declined"), outcome.observation)
        XCTAssertEqual(run.receipts.map(\.status), [.declined])
        XCTAssertFalse(run.didWrite)
    }

    func testNoAnswerCountsAsDenial() async {
        answers = [.timedOut]
        let outcome = await broker.handle(call("send_text"), run: RunState(turnKey: "t"))
        XCTAssertEqual(runs.count("send_text"), 0)
        guard case .rejected(_, _, let code) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(code, .noAnswer)
    }

    func testApprovalCenterTimesOutAsDenial() async {
        let center = ApprovalCenter()
        center.timeout = .milliseconds(50)
        let decision = await center.request(ApprovalRequest(
            id: UUID(), toolName: "x", summary: "x", payload: .object([:]), risk: .writeExternal,
            reason: "r", destination: nil, tainted: false, editableFields: [], edited: false, problem: nil))
        XCTAssertEqual(decision, .timedOut)
        XCTAssertNil(center.pending)
    }

    // MARK: Edit

    func testAnEditIsCheckedAndAskedAgainBeforeItRuns() async {
        answers = [.revised(.object(["contact": .string("Maya"), "message": .string("Running 10 min late")])), .approved]
        let run = RunState(turnKey: "t")
        let outcome = await broker.handle(
            call("send_text", ["contact": .string("Maya"), "message": .string("On my way")]), run: run)
        XCTAssertEqual(asked.count, 2, "saving an edit approves nothing: the user sees the result first")
        XCTAssertTrue(asked[1].edited)
        XCTAssertEqual(asked[1].payload["message"], .string("Running 10 min late"))
        XCTAssertEqual(runs.lastArguments("send_text")?["message"], .string("Running 10 min late"))
        XCTAssertEqual(runs.count("send_text"), 1)
        XCTAssertEqual(run.receipts.first?.edited, true)
        XCTAssertEqual(audit.entries.first?.outcome, "ok, edited by you")
        guard case .ok = outcome else { return XCTFail("\(outcome)") }
    }

    func testAnEditCannotChangeTheTarget() async {
        answers = [.revised(.object(["contact": .string("Someone Else"), "message": .string("hi")])), .denied]
        _ = await broker.handle(call("send_text", ["contact": .string("Maya"), "message": .string("hi")]),
                                run: RunState(turnKey: "t"))
        XCTAssertEqual(asked.count, 2)
        XCTAssertEqual(asked[1].problem, "Only message can be changed here.")
        XCTAssertEqual(asked[1].payload["contact"], .string("Maya"), "the refused edit changes nothing")
        XCTAssertEqual(runs.count("send_text"), 0)
    }

    // MARK: Checking arguments (I6)

    func testInvalidArgumentsNeverRun() async {
        let missing = await broker.handle(call("send_text", [:]), run: RunState(turnKey: "t"))
        guard case .invalid(let reason) = missing else { return XCTFail("\(missing)") }
        XCTAssertTrue(reason.contains("contact"), reason)

        let unknown = await broker.handle(call("does_not_exist"), run: RunState(turnKey: "t"))
        guard case .invalid(let why) = unknown else { return XCTFail("\(unknown)") }
        XCTAssertTrue(why.contains("no tool named"), why)
        XCTAssertEqual(runs.total, 0)
        XCTAssertTrue(asked.isEmpty)
    }

    func testArgumentsAreCoercedToTheSchema() throws {
        let schema = JSONSchema.object(properties: [
            "action": .string(enumValues: ["create", "list"]),
            "count": .integer(),
            "amount": .number(),
            "on": .boolean(),
            "label": .string(),
        ], required: ["action"])
        let out = try ToolArguments.canonicalize(.object([
            "action": .string("CREATE"), "count": .string("5"), "amount": .string("2.5"),
            "on": .string("true"), "label": .int(7), "extra": .string("dropped"), "gone": .null,
        ]), schema: schema)
        XCTAssertEqual(out, .object([
            "action": .string("create"), "count": .int(5), "amount": .double(2.5),
            "on": .bool(true), "label": .string("7"),
        ]))
        XCTAssertThrowsError(try ToolArguments.canonicalize(.object(["action": .string("delete")]), schema: schema))
        XCTAssertThrowsError(try ToolArguments.canonicalize(.string("not an object"), schema: schema))
    }

    /// Constructs the app can't express (anyOf, untyped items) must not make
    /// the check reject arguments a remote server accepts.
    func testUntypedMCPFieldsPassThrough() throws {
        let schema = MCPSchema.schema(from: .object([
            "type": .string("object"),
            "properties": .object([
                "filter": .object(["anyOf": .array([
                    .object(["type": .string("object")]), .object(["type": .string("null")]),
                ])]),
                "tags": .object(["type": .string("array")]),
                "limit": .object(["type": .string("integer")]),
            ]),
        ]))
        let out = try ToolArguments.canonicalize(.object([
            "filter": .object(["status": .string("open")]),
            "tags": .array([.object(["id": .int(1)])]),
            "limit": .string("10"),
        ]), schema: schema)
        XCTAssertEqual(out["filter"], .object(["status": .string("open")]))
        XCTAssertEqual(out["tags"], .array([.object(["id": .int(1)])]))
        XCTAssertEqual(out["limit"], .int(10), "declared types are still enforced")
    }

    // MARK: The sheet

    private func sampleRequest() -> ApprovalRequest {
        ApprovalRequest(id: UUID(), toolName: "send_text", summary: "Text Maya", payload: .object([:]),
                        risk: .writeExternal, reason: "Other people will see this", destination: nil,
                        tainted: false, editableFields: [], edited: false, problem: nil)
    }

    func testAfterAnEditTheSheetStaysUpUntilTheBrokerAsksAgain() async {
        let center = ApprovalCenter()
        let first = sampleRequest()
        let waiting = Task { await center.request(first) }
        for _ in 0..<100 where center.pending == nil { await Task.yield() }
        XCTAssertEqual(center.pending?.id, first.id)

        center.decide(first.id, .revised(.object(["message": .string("edited")])))
        let decision = await waiting.value
        XCTAssertEqual(decision, .revised(.object(["message": .string("edited")])))
        XCTAssertEqual(center.pending?.id, first.id, "no close-and-reopen between the edit and the re-ask")

        center.settle()
        XCTAssertNil(center.pending, "a request nobody waits on is cleared")
    }

    func testAStoppedRunRaisesNoSheet() async {
        let center = ApprovalCenter()
        let request = sampleRequest()
        let task = Task { await center.request(request) }
        task.cancel()
        let decision = await task.value
        XCTAssertEqual(decision, .cancelled)
        XCTAssertNil(center.pending)
    }

    // MARK: Never twice, and within budget

    func testTheSameWriteInOneTurnRunsOnce() async {
        let run = RunState(turnKey: "t")
        _ = await broker.handle(call("note_to_self"), run: run)
        let again = await broker.handle(call("note_to_self"), run: run)
        XCTAssertEqual(runs.count("note_to_self"), 1, "a repeated side effect replays its stored result")
        guard case .ok(_, _, let wrote) = again else { return XCTFail("\(again)") }
        XCTAssertTrue(wrote)
        XCTAssertEqual(audit.entries.first?.outcome, "replayed")

        _ = await broker.handle(call("note_to_self"), run: RunState(turnKey: "another turn"))
        XCTAssertEqual(runs.count("note_to_self"), 2, "a new turn is a new request")
    }

    func testATurnHasAToolCallBudget() async {
        let run = RunState(turnKey: "t")
        for _ in 0..<ToolBroker.maxToolCallsPerTurn {
            _ = await broker.handle(call("look_up"), run: run)
        }
        let over = await broker.handle(call("look_up"), run: run)
        guard case .rejected(_, _, let code) = over else { return XCTFail("\(over)") }
        XCTAssertEqual(code, .budget)
        XCTAssertEqual(runs.count("look_up"), ToolBroker.maxToolCallsPerTurn)
    }

    // MARK: Switches, failures and the record

    func testASwitchedOffCapabilityBlocksBeforeAnything() async {
        broker = ToolBroker(registry: registry, approvals: approvals, audit: audit,
                            capabilityBlock: { $0.name == "send_text" ? "Blocked: it's off." : nil })
        let run = RunState(turnKey: "t")
        let outcome = await broker.handle(call("send_text"), run: run)
        guard case .rejected(let reason, _, let code) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(code, .notAllowed)
        XCTAssertEqual(reason, "Blocked: it's off.")
        XCTAssertTrue(asked.isEmpty)
        XCTAssertEqual(runs.count("send_text"), 0)
        XCTAssertEqual(run.receipts.map(\.status), [.blocked])
    }

    func testAToolThatThrowsFails() async {
        registry.register(StubTool(name: "breaks", risk: .writePrivate, runs: runs, fails: true))
        let run = RunState(turnKey: "t")
        let outcome = await broker.handle(call("breaks"), run: run)
        XCTAssertTrue(outcome.observation.hasPrefix("Tool error:"), outcome.observation)
        XCTAssertTrue(outcome.observation.contains("boom"), outcome.observation)
        XCTAssertEqual(run.receipts.map(\.status), [.failed])
        XCTAssertFalse(run.didWrite)
    }

    func testEveryDecisionIsAudited() async {
        answers = [.denied]
        _ = await broker.handle(call("look_up"), run: RunState(turnKey: "t"))
        _ = await broker.handle(call("send_text"), run: RunState(turnKey: "t"))
        XCTAssertEqual(audit.entries.map(\.outcome), ["declined", "ok"], "newest first")
        XCTAssertEqual(audit.entries.first?.approved, false)
        XCTAssertNil(audit.entries.last?.approved, "a read that didn't ask has no approval")
    }
}

// MARK: - The app's tools

/// The real tools' answers to the broker, for the calls that matter most.
@MainActor
final class ToolRiskTests: XCTestCase {
    func testRiskFollowsTheInput() {
        XCTAssertEqual(CalculatorTool().risk(for: .object([:])), .read)
        XCTAssertEqual(RemindersTool().risk(for: .object(["action": .string("list")])), .read)
        XCTAssertEqual(RemindersTool().risk(for: .object(["action": .string("create")])), .writePrivate)
        XCTAssertEqual(CalendarTool().risk(for: .object(["action": .string("create")])), .writePrivate)
        XCTAssertEqual(OpenAppTool(appConfig: .default, opener: NoopURLOpener()).risk(for: .object([:])), .writeExternal)
        XCTAssertEqual(RESTConnectorTool(config: RESTConnectorConfig(
            name: "x", baseURL: "https://e.com", method: "POST")).risk(for: .object([:])), .writeExternal)
        XCTAssertEqual(RESTConnectorTool(config: RESTConnectorConfig(
            name: "x", baseURL: "https://e.com", method: "GET")).risk(for: .object([:])), .read)
    }

    func testContentWrittenByOthersIsMarked() {
        XCTAssertTrue(WebSearchTool().returnsUntrustedContent(for: .object([:])))
        XCTAssertTrue(CalendarTool().returnsUntrustedContent(for: .object(["action": .string("list")])))
        XCTAssertFalse(CalendarTool().returnsUntrustedContent(for: .object(["action": .string("create")])))
        XCTAssertFalse(CalculatorTool().returnsUntrustedContent(for: .object([:])))
    }

    /// The approval sheet reads as plain language, in the tool's own words.
    func testDescriptionsArePlainLanguage() {
        let contact = ContactActionTool(resolver: NoContacts(), opener: NoopURLOpener(), appConfig: .default)
        XCTAssertEqual(contact.describe(.object(["action": .string("call"), "contact": .string("Dad")])), "Call Dad")
        XCTAssertEqual(contact.describe(.object([
            "action": .string("text"), "contact": .string("Mom"), "message": .string("running late"),
        ])), "Text Mom: “running late”")
        XCTAssertEqual(OpenAppTool(appConfig: .default, opener: NoopURLOpener())
            .describe(.object(["url": .string("maps://?daddr=airport")])), "Open maps://?daddr=airport")
        XCTAssertEqual(ShortcutsTool(appConfig: .default, opener: NoopURLOpener())
            .describe(.object(["name": .string("Morning")])), "Run your Shortcut “Morning”")
        XCTAssertEqual(RemindersTool().describe(.object([
            "action": .string("create"), "title": .string("Buy oat milk"), "due": .string("tomorrow at 5pm"),
        ])), "Add the reminder “Buy oat milk”, due tomorrow at 5pm")
    }

    func testOpeningAWebLinkSaysWhereItGoes() {
        let tool = OpenAppTool(appConfig: .default, opener: NoopURLOpener())
        XCTAssertEqual(tool.sendsTo(.object(["url": .string("https://example.com/a")])), "example.com")
        XCTAssertNil(tool.sendsTo(.object(["url": .string("maps://?q=coffee")])))
        XCTAssertEqual(tool.approvalNote(for: .object(["url": .string("maps://?q=coffee")])), "This hands off to another app")
    }
}

// MARK: - Fakes

/// Counts executions and keeps the arguments each tool actually ran with.
@MainActor
private final class RunRecorder: Sendable {
    private var calls: [(String, JSONValue)] = []
    func add(_ name: String, _ args: JSONValue) { calls.append((name, args)) }
    func count(_ name: String) -> Int { calls.filter { $0.0 == name }.count }
    func lastArguments(_ name: String) -> JSONValue? { calls.last { $0.0 == name }?.1 }
    var total: Int { calls.count }
}

private struct StubTool: Tool {
    let name: String
    let description = "stub"
    let stubRisk: RiskTier
    let untrusted: Bool
    let destination: String?
    let runs: RunRecorder
    let editable: [EditableField]
    let fails: Bool

    init(name: String, risk: RiskTier, untrusted: Bool = false, destination: String? = nil,
         runs: RunRecorder, editable: [EditableField] = [], fails: Bool = false) {
        self.name = name
        self.stubRisk = risk
        self.untrusted = untrusted
        self.destination = destination
        self.runs = runs
        self.editable = editable
        self.fails = fails
    }

    var parameters: JSONSchema? {
        .object(properties: ["contact": .string(), "message": .string()], required: ["contact"])
    }
    func risk(for arguments: JSONValue) -> RiskTier { stubRisk }
    func describe(_ arguments: JSONValue) -> String { "\(name) for \(arguments["contact"]?.stringValue ?? "?")" }
    func sendsTo(_ arguments: JSONValue) -> String? { destination }
    func returnsUntrustedContent(for arguments: JSONValue) -> Bool { untrusted }
    var editableFields: [EditableField] { editable }

    func execute(arguments: JSONValue) async throws -> String {
        await runs.add(name, arguments)
        if fails { throw ToolError.executionFailed("boom") }
        return "ran \(name)"
    }
}

private struct NoContacts: ContactResolving {
    func resolve(name: String) async -> [ContactMatch] { [] }
}
