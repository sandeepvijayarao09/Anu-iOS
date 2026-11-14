import Foundation
import Combine

// Agents on the user's own network over the Agent2Agent protocol (Android
// parity row 19, ADR-105). Anu is only ever the client: nothing on the network
// can call into the phone.
//
// - Card discovery at `/.well-known/agent-card.json`, or the older `agent.json`.
// - `message/send` over JSON-RPC; the answer is a message, or a task whose
//   status message and artifacts carry the text.
// - Each agent is a tool, `a2a_<name>`. Its message leaves the phone for
//   another device, so it's `writeExternal`: the user approves (and may edit)
//   the exact words every time (I2), each send is ledgered (I3), and the answer
//   was written by another program, so it taints the run (P4).

// MARK: - Model

/// An agent the user added, as its card describes it.
struct A2AAgent: Codable, Equatable, Sendable, Identifiable {
    /// The address the user added (where the card was found).
    let address: String
    let name: String
    let description: String
    /// Where `message/send` goes, from the card.
    let url: String
    let skills: [String]

    var id: String { address }
    var host: String { URL(string: url)?.host?.lowercased() ?? "" }
}

enum A2AError: LocalizedError, Equatable {
    case invalidAddress
    case insecureAddress
    case noCard(String)
    case noName(String)
    case http(agent: String, status: Int)
    case agentError(agent: String, message: String)
    case noResult(String)
    case noText(String)
    case messageTooLong(Int)
    case emptyMessage

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "That isn't an http(s) address."
        case .insecureAddress: return "Plain HTTP is only allowed to an address on your own network."
        case .noCard(let base): return "No agent card at \(base)"
        case .noName(let base): return "The agent card at \(base) has no name"
        case .http(let agent, let status): return "\(agent) answered HTTP \(status)"
        case .agentError(let agent, let message): return "\(agent) said: \(message)"
        case .noResult(let agent): return "\(agent)'s reply had no result"
        case .noText(let agent): return "\(agent) answered with no text"
        case .messageTooLong(let max): return "The message is longer than \(max) characters"
        case .emptyMessage: return "The message is empty"
        }
    }
}

// MARK: - Client

struct A2AClient: Sendable {
    static let cardPaths = ["/.well-known/agent-card.json", "/.well-known/agent.json"]
    static let maxBytes = 200_000
    static let maxSkills = 8
    static let maxDescription = 200
    /// Answers share the on-device context with everything else.
    static let maxAnswer = 2_000

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// A normalized base address, or a reason it can't be an agent. Plain HTTP
    /// only to the user's own network (a Raspberry Pi serves `raspberrypi.local`).
    static func validate(_ address: String) throws -> URL {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty else {
            throw A2AError.invalidAddress
        }
        if scheme == "http", !LocalNetwork.isLocal(host) { throw A2AError.insecureAddress }
        return url
    }

    /// The agent at `address`, from its card.
    func card(at address: String) async throws -> A2AAgent {
        let base = try Self.validate(address)
        var found: [String: JSONValue]?
        for path in Self.cardPaths {
            guard let url = URL(string: path, relativeTo: base)?.absoluteURL else { continue }
            if case .object(let object)? = try? await getJSON(url) { found = object; break }
        }
        guard let card = found else { throw A2AError.noCard(base.absoluteString) }
        guard let name = card["name"]?.stringValue.map({ A2AText.clean($0, 40) }), !name.isEmpty else {
            throw A2AError.noName(base.absoluteString)
        }
        // An agent names where it answers; a relative or missing url means the
        // address it was added with.
        let endpoint = card["url"]?.stringValue.flatMap { URL(string: $0, relativeTo: base)?.absoluteURL } ?? base
        _ = try Self.validate(endpoint.absoluteString)
        var skills: [String] = []
        if case .array(let list)? = card["skills"] {
            skills = list.compactMap { ($0["name"] ?? $0["id"])?.stringValue }.map { A2AText.clean($0, 40) }
        }
        return A2AAgent(
            address: base.absoluteString, name: name,
            description: A2AText.clean(card["description"]?.stringValue ?? "", Self.maxDescription),
            url: endpoint.absoluteString, skills: Array(skills.prefix(Self.maxSkills)))
    }

    /// Sends `text` and returns the text of the answer: a message, or a task's
    /// status message and artifacts.
    func send(_ text: String, to agent: A2AAgent) async throws -> String {
        let url = try Self.validate(agent.url)
        let body: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .string(UUID().uuidString),
            "method": .string("message/send"),
            "params": .object(["message": .object([
                "kind": .string("message"),
                "role": .string("user"),
                "messageId": .string(UUID().uuidString),
                "parts": .array([.object(["kind": .string("text"), "text": .string(text)])]),
            ])]),
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 25
        let (data, response) = try await session.data(for: request, delegate: VaultNoRedirects.shared)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw A2AError.http(agent: agent.name, status: status) }
        guard case .object(let reply)? = try? JSONDecoder().decode(JSONValue.self, from: data.prefix(Self.maxBytes)) else {
            throw A2AError.noResult(agent.name)
        }
        if let error = reply["error"], !error.isNull {
            throw A2AError.agentError(agent: agent.name,
                                      message: A2AText.clean(error["message"]?.stringValue ?? "an error", 200))
        }
        guard let result = reply["result"], case .object = result else { throw A2AError.noResult(agent.name) }
        var texts = Self.texts(result["parts"])
        texts += Self.texts(result["status"]?["message"]?["parts"])
        if case .array(let artifacts)? = result["artifacts"] {
            for artifact in artifacts { texts += Self.texts(artifact["parts"]) }
        }
        let answer = A2AText.clean(texts.joined(separator: "\n"), Self.maxAnswer)
        guard !answer.isEmpty else { throw A2AError.noText(agent.name) }
        return answer
    }

    static func texts(_ parts: JSONValue?) -> [String] {
        guard case .array(let list)? = parts else { return [] }
        return list.compactMap { part in
            if let kind = part["kind"]?.stringValue, kind != "text" { return nil }
            return part["text"]?.stringValue
        }
    }

    private func getJSON(_ url: URL) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (data, response) = try await session.data(for: request, delegate: VaultNoRedirects.shared)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw A2AError.noCard(url.absoluteString)
        }
        return try JSONDecoder().decode(JSONValue.self, from: data.prefix(Self.maxBytes))
    }
}

/// Text from another device, made safe to show a model: no control
/// characters, and short.
enum A2AText {
    static func clean(_ text: String, _ max: Int) -> String {
        let plain = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            $0 == "\n" || !CharacterSet.controlCharacters.contains($0)
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.count > max ? String(plain.prefix(max)).trimmingCharacters(in: .whitespaces) + "…" : plain
    }
}

// MARK: - Tool

/// One agent on the user's network as a tool.
struct A2AAgentTool: Tool {
    static let maxMessage = 1_000

    let agent: A2AAgent
    private let client: A2AClient
    /// nil records to `PrivacyLedger.shared`; tests pass their own.
    private let ledger: PrivacyLedger?

    init(agent: A2AAgent, client: A2AClient = A2AClient(), ledger: PrivacyLedger? = nil) {
        self.agent = agent
        self.client = client
        self.ledger = ledger
    }

    /// "Home Lab" → `a2a_home_lab`.
    static func toolName(_ agentName: String) -> String {
        let snake = agentName.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return "a2a_" + (snake.isEmpty ? "agent" : String(snake.prefix(50)))
    }

    var name: String { Self.toolName(agent.name) }

    var description: String {
        "\(agent.name), an agent the user added on their own network"
            + (agent.description.isEmpty ? "" : ": \(agent.description)")
            + (agent.skills.isEmpty ? "" : ". It can: \(agent.skills.joined(separator: ", "))")
    }

    var parameters: JSONSchema? {
        .object(
            description: "A message for the agent",
            properties: ["message": .string(description: "What to ask or tell the agent, in the user's words")],
            required: ["message"])
    }

    var sideEffect: ToolSideEffect { .external(capability: .connector) }
    func risk(for arguments: JSONValue) -> RiskTier { .writeExternal }
    func sendsTo(_ arguments: JSONValue) -> String? { agent.host }
    func returnsUntrustedContent(for arguments: JSONValue) -> Bool { true }
    var editableFields: [EditableField] { [EditableField(key: "message", label: "Message", kind: .text)] }
    func approvalNote(for arguments: JSONValue) -> String? {
        "This goes to \(agent.name) at \(agent.host), another device on your network"
    }

    func describe(_ arguments: JSONValue) -> String {
        "Ask \(agent.name) (\(agent.host)): "
            + ToolDescribing.quoted(ToolDescribing.text(arguments, "message") ?? "…", limit: Self.maxMessage)
    }

    func execute(arguments: JSONValue) async throws -> String {
        let message = (arguments["message"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw A2AError.emptyMessage }
        guard message.count <= Self.maxMessage else { throw A2AError.messageTooLong(Self.maxMessage) }
        // The user approved these exact words, so they go unchanged; the
        // ledger records them before they leave.
        let destination = EgressDestination.a2aAgent(name: agent.name, host: agent.host)
        if let ledger {
            await ledger.record(destination: destination, payload: message, redactions: 0)
        } else {
            await PrivacyLedger.shared.record(destination: destination, payload: message, redactions: 0)
        }
        let answer = try await client.send(message, to: agent)
        return "\(agent.name) (another program on the user's network) answered:\n\(answer)"
    }
}

// MARK: - The user's list

/// The addresses the user added, encrypted at rest via `SecureFile`.
struct A2AAgentStore: Sendable {
    let fileURL: URL?

    static let `default` = A2AAgentStore(fileURL: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("a2a_agents.json"))

    func load() -> [String] {
        guard let fileURL, let data = SecureFile.read(fileURL) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    func save(_ addresses: [String]) {
        guard let fileURL, let data = try? JSONEncoder().encode(addresses) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? SecureFile.write(data, to: fileURL)
    }
}

/// The agents the user added, with their cards. `refresh()` fetches each card
/// once; an agent that doesn't answer is left out until the next refresh and
/// says why in `problems`.
@MainActor
final class A2AAgents: ObservableObject {
    static let shared = A2AAgents(store: .default)

    @Published private(set) var addresses: [String]
    @Published private(set) var agents: [A2AAgent] = []
    @Published private(set) var problems: [String: String] = [:]

    private let store: A2AAgentStore
    private let client: A2AClient
    private let ledger: PrivacyLedger?

    init(store: A2AAgentStore, client: A2AClient = A2AClient(), ledger: PrivacyLedger? = nil) {
        self.store = store
        self.client = client
        self.ledger = ledger
        self.addresses = store.load()
    }

    var tools: [any Tool] {
        agents.map { A2AAgentTool(agent: $0, client: client, ledger: ledger) }
    }

    func refresh() async {
        // Concurrently, so one agent that doesn't answer can't hold up the rest.
        let list = addresses
        let client = self.client
        let outcomes = await withTaskGroup(of: (Int, A2AAgent?, String?).self) { group in
            for (index, address) in list.enumerated() {
                group.addTask {
                    do { return (index, try await client.card(at: address), nil) } catch {
                        return (index, nil, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                    }
                }
            }
            var collected: [(Int, A2AAgent?, String?)] = []
            for await outcome in group { collected.append(outcome) }
            return collected.sorted { $0.0 < $1.0 }
        }
        guard !Task.isCancelled else { return }
        var found: [A2AAgent] = []
        var failed: [String: String] = [:]
        for (index, agent, problem) in outcomes {
            if let agent {
                // Two agents with one name would share a tool name: the first wins.
                if !found.contains(where: { A2AAgentTool.toolName($0.name) == A2AAgentTool.toolName(agent.name) }) {
                    found.append(agent)
                }
            } else {
                failed[list[index]] = problem ?? "No answer"
            }
        }
        agents = found
        problems = failed
    }

    /// Adds an address after checking it's one Anu may talk to. The card is
    /// fetched on the next `refresh()`.
    func add(_ address: String) throws {
        let url = try A2AClient.validate(address).absoluteString
        guard !addresses.contains(url) else { return }
        addresses.append(url)
        store.save(addresses)
    }

    func remove(_ address: String) {
        addresses.removeAll { $0 == address }
        agents.removeAll { $0.address == address }
        problems[address] = nil
        store.save(addresses)
    }
}
