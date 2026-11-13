import Foundation
import CryptoKit

// MARK: - Run state

/// What the broker knows about the turn it serves. One per user message; the
/// planner's sub-agents share their turn's state.
@MainActor
final class RunState {
    let runID = UUID()
    /// Identifies the user turn. The same turn's calls share idempotency keys,
    /// so a repeated call replays instead of acting twice.
    let turnKey: String
    /// True once the run has read content written by others (P4). A tainted run
    /// loses its automatic permissions.
    private(set) var tainted = false
    private(set) var toolCalls = 0
    /// What really happened, shown under the answer.
    private(set) var receipts: [ActionReceipt] = []
    /// The one repair attempt for an answer that claims an action that never
    /// happened, or leaks control markup, has been used.
    var answerRepairUsed = false

    init(turnKey: String) {
        self.turnKey = turnKey
    }

    /// Whether a call in this run actually changed something.
    var didWrite: Bool { receipts.contains { $0.status == .done } }

    func taint() { tainted = true }
    func countCall() { toolCalls += 1 }
    func add(_ receipt: ActionReceipt) { receipts.append(receipt) }
}

// MARK: - Tool Broker

/// The only way a model-proposed tool call is executed (ARCHITECTURE §4, P2),
/// ported from Anu Android. In order, it:
/// 1. checks the arguments against the tool's schema and re-encodes them (I6);
/// 2. applies policy: capability switches, risk tier and taint;
/// 3. replays a stored result instead of repeating a side effect;
/// 4. asks for approval of the exact payload when required (I2). A timeout
///    counts as a denial. The user may edit the fields a tool allows; the edit
///    is checked like the model's arguments and asked again;
/// 5. executes with a timeout, stores, audits, and writes the receipt.
@MainActor
final class ToolBroker {
    /// Tool calls one user turn may make (Anu Android: 12).
    static let maxToolCallsPerTurn = 12
    nonisolated static let toolTimeout: Duration = .seconds(30)
    /// Escalation to a bigger model (your Mac, Gemini, a private server) may
    /// load a large model cold and write a long answer; 30 s cut those off.
    nonisolated static let escalationTimeout: Duration = .seconds(180)

    private let registry: ToolRegistry
    private let approvals: ApprovalCenter
    private let audit: ToolAuditLog
    /// A reason when a capability the tool needs is switched off in Settings.
    private let capabilityBlock: @MainActor (any Tool) -> String?
    /// Results of side-effecting calls by idempotency key, for this app run.
    private var results: [String: String] = [:]

    init(
        registry: ToolRegistry,
        approvals: ApprovalCenter,
        audit: ToolAuditLog,
        capabilityBlock: @escaping @MainActor (any Tool) -> String? = { _ in nil }
    ) {
        self.registry = registry
        self.approvals = approvals
        self.audit = audit
        self.capabilityBlock = capabilityBlock
    }

    func handle(_ call: ToolCallInfo, run: RunState) async -> ToolOutcome {
        guard let tool = registry.tool(named: call.name) else {
            // A model often calls a skill as if it were a tool (ADR-120).
            if let skill = SkillTools.notAToolMessage(call.name, registry: registry) {
                return .invalid(reason: skill)
            }
            let known = registry.toolNames.joined(separator: ", ")
            return .invalid(reason: "There is no tool named \(call.name). Available: \(known)")
        }
        guard run.toolCalls < Self.maxToolCallsPerTurn else {
            return .rejected(
                reason: "This request has used its \(Self.maxToolCallsPerTurn) tool calls. Answer with what you have.",
                summary: "", code: .budget)
        }
        run.countCall()

        var current: Assessed
        do {
            current = try Self.assess(tool, call.arguments)
        } catch {
            return .invalid(reason: "The arguments for \(tool.name) are not valid: \(error.localizedDescription)")
        }

        if let blocked = capabilityBlock(tool) {
            record(tool, current, run, outcome: "blocked: capability off", approved: nil)
            run.add(ActionReceipt(toolName: tool.name, summary: current.summary, status: .blocked))
            return .rejected(reason: blocked, summary: current.summary, code: .notAllowed)
        }

        let proposedKey = Self.idempotencyKey(run.turnKey, tool.name, current.payload)
        var key = proposedKey
        if current.risk != .read, let stored = results[key] {
            record(tool, current, run, outcome: "replayed", approved: nil)
            return .ok(result: stored, summary: current.summary, wrote: true)
        }

        // Ask until the user approves, declines or doesn't answer. An edit
        // approves nothing: it is checked like the model's arguments and asked
        // again with exactly what will run (I2).
        var reason = Self.approvalReason(tool, current, tainted: run.tainted)
        let asked = reason != nil
        // However the approval ends, the sheet never outlives it.
        defer { if asked { approvals.settle() } }
        var edited = false
        var problem: String?
        while let why = reason {
            let request = ApprovalRequest(
                id: UUID(), toolName: tool.name, summary: current.summary, payload: current.payload,
                risk: current.risk, reason: why, destination: current.destination, tainted: run.tainted,
                editableFields: tool.editableFields, edited: edited, problem: problem)
            switch await approvals.request(request) {
            case .approved:
                reason = nil
            case .denied:
                record(tool, current, run, outcome: "declined", approved: false)
                run.add(ActionReceipt(toolName: tool.name, summary: current.summary, status: .declined, edited: edited))
                return .rejected(
                    reason: "The user was shown this and declined, so nothing was done. Don't try again unless they ask.",
                    summary: current.summary, code: .declined)
            case .timedOut:
                record(tool, current, run, outcome: "no answer in time", approved: false)
                run.add(ActionReceipt(toolName: tool.name, summary: current.summary, status: .noAnswer, edited: edited))
                return .rejected(
                    reason: "Nobody answered the approval in time, so nothing was done.",
                    summary: current.summary, code: .noAnswer)
            case .cancelled:
                record(tool, current, run, outcome: "cancelled", approved: false)
                return .rejected(reason: "The request was stopped, so nothing was done.",
                                 summary: current.summary, code: .cancelled)
            case .revised(let payload):
                do {
                    guard let revised = try Self.revise(tool, current, edited: payload) else { continue }
                    current = revised
                } catch {
                    problem = error.localizedDescription
                    continue
                }
                key = Self.idempotencyKey(run.turnKey, tool.name, current.payload)
                edited = true
                problem = nil
                if current.risk != .read, let stored = results[key] {
                    record(tool, current, run, outcome: "replayed", approved: nil)
                    return .ok(result: stored, summary: current.summary, wrote: true)
                }
                // The user always sees the final payload before it runs, even
                // when it would no longer need asking.
                reason = Self.approvalReason(tool, current, tainted: run.tainted) ?? "You changed this"
            }
        }

        let result = await Self.invoke(tool, current.payload)
        switch result {
        case .failure(let error):
            let message = error.localizedDescription
            record(tool, current, run, outcome: "failed: \(message)", approved: asked ? true : nil)
            if current.risk != .read {
                run.add(ActionReceipt(toolName: tool.name, summary: current.summary, status: .failed, edited: edited))
            }
            return .failed(reason: message, summary: current.summary)
        case .success(let output):
            if current.risk != .read {
                results[key] = output
                // A retry of the model's original call replays what the user's
                // edit did, instead of acting again.
                if key != proposedKey { results[proposedKey] = output }
                run.add(ActionReceipt(toolName: tool.name, summary: current.summary, status: .done, edited: edited))
            }
            if tool.returnsUntrustedContent(for: current.payload) { run.taint() }
            record(tool, current, run, outcome: edited ? "ok, edited by you" : "ok", approved: asked ? true : nil)
            return .ok(result: output, summary: current.summary, wrote: current.risk != .read)
        }
    }

    // MARK: - Assessment

    /// A call's payload after validation, and what the tool says about it.
    struct Assessed: Equatable {
        let payload: JSONValue
        let risk: RiskTier
        let summary: String
        let destination: String?
    }

    static func assess(_ tool: any Tool, _ arguments: JSONValue) throws -> Assessed {
        let payload = try ToolArguments.canonicalize(arguments, schema: tool.parameters)
        // The tool's own checks, before anyone is asked to approve it.
        try tool.validate(payload)
        return Assessed(payload: payload, risk: tool.risk(for: payload),
                        summary: tool.describe(payload), destination: tool.sendsTo(payload))
    }

    /// The user's change, checked like the model's arguments: only the tool's
    /// editable fields may differ, and the result must pass the schema. Nil when
    /// nothing changed.
    static func revise(_ tool: any Tool, _ current: Assessed, edited: JSONValue) throws -> Assessed? {
        guard var fields = edited.objectValue else { throw ToolArguments.Problem("That change isn't valid.") }
        let before = current.payload.objectValue ?? [:]
        // Optional fields left empty are removed.
        for field in tool.editableFields where field.optional {
            if let text = fields[field.key]?.stringValue,
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fields[field.key] = nil
            }
        }
        let changed = Set(before.keys).union(fields.keys).filter { before[$0] != fields[$0] }
        guard !changed.isEmpty else { return nil }
        let allowed = Set(tool.editableFields.map(\.key))
        guard changed.isSubset(of: allowed) else {
            let labels = tool.editableFields.map { $0.label.lowercased() }.joined(separator: ", ")
            throw ToolArguments.Problem(allowed.isEmpty
                ? "This can't be changed here."
                : "Only \(labels) can be changed here.")
        }
        let revised = try assess(tool, .object(fields))
        return revised.payload == current.payload ? nil : revised
    }

    /// Why a call needs the user's approval, or nil when it runs by itself.
    static func approvalReason(_ tool: any Tool, _ call: Assessed, tainted: Bool) -> String? {
        switch call.risk {
        case .read:
            // Injected text could otherwise send the user's data to a third party.
            guard tainted, let host = call.destination else { return nil }
            return "This sends data to \(host) after reading content written by others"
        case .writePrivate:
            return tainted ? "This request read content written by others" : nil
        case .writeExternal:
            if let note = tool.approvalNote(for: call.payload) { return note }
            if let host = call.destination { return "This goes to \(host), outside your phone" }
            return "Other people will see this"
        case .destructive:
            if let host = call.destination { return "This goes to \(host), and may not be undoable there" }
            return tool.approvalNote(for: call.payload) ?? "This can't be undone"
        }
    }

    /// Content-based, so the same call in the same turn gets the same key.
    static func idempotencyKey(_ turnKey: String, _ tool: String, _ payload: JSONValue) -> String {
        let digest = SHA256.hash(data: Data("\(turnKey)|\(tool)|\(payload.canonicalJSON)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Execution

    /// Races the tool against a timeout, so a hung tool can't stall the loop.
    nonisolated static func invoke(_ tool: any Tool, _ payload: JSONValue) async -> Result<String, Error> {
        await withTaskGroup(of: Result<String, Error>.self) { group in
            group.addTask {
                do {
                    return .success(try await tool.execute(arguments: payload))
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                let limit = tool.timeout
                try? await Task.sleep(for: limit)
                let seconds = Int(limit.components.seconds)
                return .failure(ToolError.executionFailed("'\(tool.name)' timed out after \(seconds) seconds"))
            }
            let first = await group.next() ?? .failure(ToolError.executionFailed("no result"))
            group.cancelAll()
            return first
        }
    }

    private func record(_ tool: any Tool, _ call: Assessed, _ run: RunState, outcome: String, approved: Bool?) {
        audit.record(ToolAuditEntry(
            runID: run.runID, toolName: tool.name, risk: call.risk, summary: call.summary,
            destination: call.destination, outcome: outcome, approved: approved))
    }
}

// MARK: - Argument checking (I6)

/// Checks a call's arguments against the tool's schema and re-encodes them, so
/// the payload the user approves is exactly the payload that runs.
enum ToolArguments {
    struct Problem: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// - Top-level keys the schema doesn't declare are dropped: they can't cause
    ///   an action, and what runs must be what was approved.
    /// - Required keys must be present. Nulls count as absent.
    /// - Values are coerced where the model's intent is unambiguous ("5" for an
    ///   integer, 5 for a string), and enums take the schema's own spelling.
    static func canonicalize(_ arguments: JSONValue, schema: JSONSchema?) throws -> JSONValue {
        let object: [String: JSONValue]
        switch arguments {
        case .object(let o): object = o
        case .null: object = [:]
        default: throw Problem("Arguments must be a JSON object.")
        }
        guard let schema, let properties = schema.properties, !properties.isEmpty else {
            return .object(object.filter { !$0.value.isNull })
        }
        var out: [String: JSONValue] = [:]
        for (key, value) in object where !value.isNull {
            guard let property = properties[key] else { continue }
            out[key] = try coerce(value, to: property, path: key)
        }
        let missing = (schema.required ?? []).filter { out[$0] == nil }.sorted()
        guard missing.isEmpty else {
            throw Problem("Missing required \(missing.count == 1 ? "argument" : "arguments"): \(missing.joined(separator: ", ")).")
        }
        return .object(out)
    }

    private static func coerce(_ value: JSONValue, to schema: JSONSchema, path: String) throws -> JSONValue {
        if schema.acceptsAnyValue { return value }
        switch schema.type {
        case .string:
            let text: String
            switch value {
            case .string(let s): text = s
            case .int(let i): text = String(i)
            case .double(let d): text = String(d)
            case .bool(let b): text = b ? "true" : "false"
            default: throw Problem("\(path) must be text.")
            }
            guard let choices = schema.enumValues?.compactMap(\.stringValue), !choices.isEmpty else {
                return .string(text)
            }
            guard let match = choices.first(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) else {
                throw Problem("\(path) must be one of: \(choices.joined(separator: ", ")).")
            }
            return .string(match)
        case .integer:
            switch value {
            case .int: return value
            case .double(let d) where d.rounded() == d && abs(d) < 9e15: return .int(Int(d))
            case .string(let s):
                if let i = Int(s.trimmingCharacters(in: .whitespaces)) { return .int(i) }
            default: break
            }
            throw Problem("\(path) must be a whole number.")
        case .number:
            switch value {
            case .int, .double: return value
            case .string(let s):
                if let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite { return .double(d) }
            default: break
            }
            throw Problem("\(path) must be a number.")
        case .boolean:
            switch value {
            case .bool: return value
            case .string(let s) where ["true", "false"].contains(s.lowercased()): return .bool(s.lowercased() == "true")
            default: throw Problem("\(path) must be true or false.")
            }
        case .array:
            guard case .array(let items) = value else { throw Problem("\(path) must be a list.") }
            guard let itemSchema = schema.items else { return value }
            return .array(try items.enumerated().map { try coerce($0.element, to: itemSchema, path: "\(path)[\($0.offset)]") })
        case .object:
            guard case .object(let nested) = value else { throw Problem("\(path) must be an object.") }
            // Nested objects keep every key (a REST query or body is free-form);
            // only declared properties are type-checked.
            guard let properties = schema.properties, !properties.isEmpty else { return value }
            var out = nested
            for (key, item) in nested where !item.isNull {
                if let property = properties[key] {
                    out[key] = try coerce(item, to: property, path: "\(path).\(key)")
                }
            }
            return .object(out)
        case .null:
            return .null
        }
    }
}
