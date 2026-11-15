import XCTest
@testable import Anu

/// The A2A client for agents on the user's network (ADR-105): the card and its
/// older address, `message/send`, a task's status and artifacts, an agent's
/// error, the tool through the broker (asks every time, ledgers, taints), and
/// the user's list with an agent that doesn't answer.
@MainActor
final class A2AClientTests: XCTestCase {
    private let base = "http://10.0.2.2:8768/"
    private static let card = #"""
    {"name":"Home Lab","description":"A made-up lab with a desk lamp","url":"http://10.0.2.2:8768/a2a",
     "skills":[{"id":"room","name":"Room status"},{"id":"lamp","name":"Desk lamp"}]}
    """#
    private static let messageReply = #"""
    {"jsonrpc":"2.0","id":"1","result":{"kind":"message","role":"agent","parts":[{"kind":"text","text":"The lab is 21.5 °C."}]}}
    """#

    private var ledger: PrivacyLedger!
    private var client: A2AClient!

    override func setUp() async throws {
        ledger = PrivacyLedger(persists: false)
        ledger.beginTurn()
        client = A2AClient(session: LANStub.session())
        LANStub.answer { _ in .init(status: 404, body: "{}") }
    }

    private func homeLab() -> A2AAgent {
        A2AAgent(address: base, name: "Home Lab", description: "", url: "http://10.0.2.2:8768/a2a", skills: [])
    }

    // MARK: Card

    func testCardFromTheWellKnownAddress() async throws {
        LANStub.answer { request in
            request.url?.path == "/.well-known/agent-card.json" ? .init(body: Self.card) : .init(status: 404)
        }
        let agent = try await client.card(at: base)
        XCTAssertEqual(agent.name, "Home Lab")
        XCTAssertEqual(agent.url, "http://10.0.2.2:8768/a2a")
        XCTAssertEqual(agent.host, "10.0.2.2")
        XCTAssertEqual(agent.skills, ["Room status", "Desk lamp"])
        XCTAssertEqual(LANStub.requests.count, 1)
    }

    func testCardFromTheOlderAddress() async throws {
        LANStub.answer { request in
            request.url?.path == "/.well-known/agent.json" ? .init(body: Self.card) : .init(status: 404)
        }
        let agent = try await client.card(at: base)
        XCTAssertEqual(agent.name, "Home Lab")
        XCTAssertEqual(LANStub.requests.map { $0.request.url?.path },
                       ["/.well-known/agent-card.json", "/.well-known/agent.json"])
    }

    func testNoCardAndNoName() async {
        do { _ = try await client.card(at: base); XCTFail() } catch {
            XCTAssertEqual(error as? A2AError, .noCard(base))
        }
        LANStub.answer { _ in .init(body: #"{"description":"nameless"}"#) }
        do { _ = try await client.card(at: base); XCTFail() } catch {
            XCTAssertEqual(error as? A2AError, .noName(base))
        }
    }

    func testRelativeCardURLAndControlCharactersAreCleaned() async throws {
        LANStub.answer { _ in .init(body: #"{"name":"Lab\u0007 Bot","url":"/rpc"}"#) }
        let agent = try await client.card(at: "raspberrypi.local:8000")
        XCTAssertEqual(agent.name, "Lab Bot")
        XCTAssertEqual(agent.url, "http://raspberrypi.local:8000/rpc")
    }

    func testPlainHTTPOnlyOnTheLocalNetwork() async {
        XCTAssertThrowsError(try A2AClient.validate("http://agents.example.com")) {
            XCTAssertEqual($0 as? A2AError, .insecureAddress)
        }
        XCTAssertNoThrow(try A2AClient.validate("https://agents.example.com"))
        XCTAssertThrowsError(try A2AClient.validate("ftp://x")) { XCTAssertEqual($0 as? A2AError, .invalidAddress) }
        // A card on the LAN can't point the message at a public host over HTTP.
        LANStub.answer { _ in .init(body: #"{"name":"Sneaky","url":"http://203.0.113.9/a2a"}"#) }
        do { _ = try await client.card(at: base); XCTFail() } catch {
            XCTAssertEqual(error as? A2AError, .insecureAddress)
        }
    }

    // MARK: message/send

    func testSendAMessage() async throws {
        LANStub.answer { _ in .init(body: Self.messageReply) }
        let answer = try await client.send("What's the temperature?", to: homeLab())
        XCTAssertEqual(answer, "The lab is 21.5 °C.")

        let (request, body) = LANStub.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "http://10.0.2.2:8768/a2a")
        XCTAssertEqual(request.httpMethod, "POST")
        let rpc = try JSONDecoder().decode(JSONValue.self, from: body)
        XCTAssertEqual(rpc["jsonrpc"], .string("2.0"))
        XCTAssertEqual(rpc["method"], .string("message/send"))
        XCTAssertEqual(rpc["params"]?["message"]?["role"], .string("user"))
        XCTAssertEqual(rpc["params"]?["message"]?["parts"]?[0]?["text"], .string("What's the temperature?"))
    }

    func testATaskAnswersWithItsStatusMessageAndArtifacts() async throws {
        LANStub.answer { _ in .init(body: #"""
        {"jsonrpc":"2.0","id":"1","result":{"kind":"task","id":"t1",
          "status":{"state":"completed","message":{"kind":"message","parts":[{"kind":"text","text":"The desk lamp is on."}]}},
          "artifacts":[{"artifactId":"a1","parts":[{"kind":"text","text":"Lamp is on."},{"kind":"file","file":{}}]}]}}
        """#) }
        let answer = try await client.send("Turn on the lamp", to: homeLab())
        XCTAssertEqual(answer, "The desk lamp is on.\nLamp is on.")
    }

    func testAnAgentsErrorAndHTTPFailures() async {
        LANStub.answer { _ in .init(body: #"{"jsonrpc":"2.0","id":"1","error":{"code":-32601,"message":"Method not found"}}"#) }
        do { _ = try await client.send("hi", to: homeLab()); XCTFail() } catch {
            XCTAssertEqual(error as? A2AError, .agentError(agent: "Home Lab", message: "Method not found"))
        }
        LANStub.answer { _ in .init(status: 503) }
        do { _ = try await client.send("hi", to: homeLab()); XCTFail() } catch {
            XCTAssertEqual(error as? A2AError, .http(agent: "Home Lab", status: 503))
        }
        LANStub.answer { _ in .init(body: #"{"jsonrpc":"2.0","id":"1","result":{"kind":"message","parts":[]}}"#) }
        do { _ = try await client.send("hi", to: homeLab()); XCTFail() } catch {
            XCTAssertEqual(error as? A2AError, .noText("Home Lab"))
        }
    }

    // MARK: The tool, through the broker

    func testTheToolAsksEveryTimeLedgersAndTaints() async throws {
        let registry = ToolRegistry()
        let approvals = ApprovalCenter()
        var asked: [ApprovalRequest] = []
        approvals.autoDecide = { request in asked.append(request); return .approved }
        let broker = ToolBroker(registry: registry, approvals: approvals, audit: ToolAuditLog(fileURL: nil))
        let tool = A2AAgentTool(agent: homeLab(), client: client, ledger: ledger)
        registry.register(tool)
        XCTAssertEqual(tool.name, "a2a_home_lab")
        XCTAssertEqual(A2AAgentTool.toolName("Señor Bot 3000!"), "a2a_se_or_bot_3000")

        LANStub.answer { _ in .init(body: Self.messageReply) }
        let run = RunState(turnKey: "t")
        let call = ToolCallInfo(name: "a2a_home_lab", arguments: .object(["message": .string("What's the temperature?")]))
        let outcome = await broker.handle(call, run: run)

        XCTAssertEqual(asked.count, 1, "a message to another device always asks")
        XCTAssertEqual(asked.first?.risk, .writeExternal)
        XCTAssertEqual(asked.first?.destination, "10.0.2.2")
        XCTAssertEqual(asked.first?.summary, "Ask Home Lab (10.0.2.2): “What's the temperature?”")
        XCTAssertEqual(asked.first?.editableFields.map(\.key), ["message"])
        guard case .ok(let result, _, let wrote) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(result.contains("The lab is 21.5 °C."))
        XCTAssertTrue(wrote)
        XCTAssertTrue(run.tainted, "the answer was written by another program")
        XCTAssertEqual(ledger.events.map(\.destination), [.a2aAgent(name: "Home Lab", host: "10.0.2.2")])
        XCTAssertEqual(ledger.events.first?.payloadSummary, "What's the temperature?")

        // Asked again for a second message in the same turn.
        let second = ToolCallInfo(name: "a2a_home_lab", arguments: .object(["message": .string("And humidity?")]))
        _ = await broker.handle(second, run: run)
        XCTAssertEqual(asked.count, 2)
    }

    func testDeclinedMessageNeverLeaves() async {
        let registry = ToolRegistry()
        let approvals = ApprovalCenter()
        approvals.autoDecide = { _ in .denied }
        let broker = ToolBroker(registry: registry, approvals: approvals, audit: ToolAuditLog(fileURL: nil))
        registry.register(A2AAgentTool(agent: homeLab(), client: client, ledger: ledger))
        let outcome = await broker.handle(
            ToolCallInfo(name: "a2a_home_lab", arguments: .object(["message": .string("hi")])), run: RunState(turnKey: "t"))
        guard case .rejected(_, _, let code) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(code, .declined)
        XCTAssertTrue(LANStub.requests.isEmpty)
        XCTAssertTrue(ledger.events.isEmpty)
    }

    func testTooLongAMessageIsRefused() async {
        let tool = A2AAgentTool(agent: homeLab(), client: client, ledger: ledger)
        do {
            _ = try await tool.execute(arguments: .object(["message": .string(String(repeating: "a", count: 1_001))]))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? A2AError, .messageTooLong(1_000))
        }
        XCTAssertTrue(LANStub.requests.isEmpty)
    }

    // MARK: The user's list

    func testAddListRemoveAndAnAgentThatDoesntAnswer() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("a2a-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = A2AAgentStore(fileURL: file)
        let agents = A2AAgents(store: store, client: client, ledger: ledger)

        try agents.add(base)
        try agents.add("http://10.0.2.3:9000/")
        try agents.add(base)   // no duplicates
        XCTAssertThrowsError(try agents.add("http://public.example.com"))
        XCTAssertEqual(agents.addresses, [base, "http://10.0.2.3:9000/"])
        XCTAssertEqual(store.load(), agents.addresses, "saved through SecureFile")

        LANStub.answer { request in
            request.url?.host == "10.0.2.2" && request.url?.path == "/.well-known/agent-card.json"
                ? .init(body: Self.card) : .init(status: 404)
        }
        await agents.refresh()
        XCTAssertEqual(agents.agents.map(\.name), ["Home Lab"])
        XCTAssertEqual(agents.tools.map(\.name), ["a2a_home_lab"])
        XCTAssertNotNil(agents.problems["http://10.0.2.3:9000/"], "the silent agent says why it's missing")

        agents.remove(base)
        XCTAssertEqual(agents.addresses, ["http://10.0.2.3:9000/"])
        XCTAssertTrue(agents.tools.isEmpty)
        XCTAssertEqual(A2AAgents(store: store, client: client).addresses, ["http://10.0.2.3:9000/"])
    }
}
