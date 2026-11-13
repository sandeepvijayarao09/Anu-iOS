import Foundation

// MARK: - Tool policy types
//
// The vocabulary the Tool Broker decides with (ARCHITECTURE §4, ported from
// Anu Android's ToolBroker). Tools describe themselves with these; they never
// decide whether they run — the broker does.

/// How much a tool call can affect the world. Risk can depend on the input: a
/// reminder list is a read, creating one a private write.
enum RiskTier: String, Codable, Sendable, CaseIterable {
    /// No side effects. Runs by itself — unless the run is tainted and the call
    /// sends data to a third party.
    case read
    /// Changes only the user's own data and can be undone (a reminder, an event
    /// without attendees). Runs by itself unless the run is tainted.
    case writePrivate
    /// Visible to others, or leaves Anu's control (a text, a call, another app,
    /// a remote service). Always needs approval of the exact payload (I2).
    case writeExternal
    /// Deletes, or can't be undone. Always needs approval.
    case destructive

    var label: String {
        switch self {
        case .read: return "Read"
        case .writePrivate: return "Private change"
        case .writeExternal: return "Leaves Anu"
        case .destructive: return "Can't be undone"
        }
    }
}

/// A payload field the user may change on the approval sheet before approving.
/// Identifiers, times and anything that picks a target stay out, so an edit
/// can't redirect an action.
struct EditableField: Sendable, Equatable, Hashable {
    enum Kind: Sendable, Equatable, Hashable {
        /// One line of text, such as a subject.
        case line
        /// Free text, such as a message body.
        case text
    }

    let key: String
    let label: String
    let kind: Kind
    /// An optional field left empty is removed from the payload.
    var optional: Bool = false
}

/// Why the broker refused a call. The model reads the code, so it can tell a
/// person's "no" from a rule (on Anu Android a bare "not allowed" for a
/// declined reply made the model blame "the system").
enum RefusalCode: String, Codable, Sendable {
    /// The user saw it and said no.
    case declined
    /// Nobody answered the approval in time.
    case noAnswer = "no_answer"
    /// Policy: a capability is switched off.
    case notAllowed = "not_allowed"
    /// The turn used up its tool calls.
    case budget
    /// The run was stopped.
    case cancelled
}

/// The broker's verdict on one call. Every outcome goes back to the model as
/// the tool's result. `summary` is the tool's own description of the call,
/// never the model's words.
enum ToolOutcome: Sendable, Equatable {
    /// `wrote` is true when the call changed something, so an answer may
    /// truthfully say it acted.
    case ok(result: String, summary: String, wrote: Bool)
    /// Unknown tool or arguments that don't fit the schema. Never executed (I6).
    case invalid(reason: String)
    /// Blocked by policy, or the user said no.
    case rejected(reason: String, summary: String, code: RefusalCode)
    /// The tool itself failed.
    case failed(reason: String, summary: String)

    /// What the model reads back as the tool's result.
    var observation: String {
        switch self {
        case .ok(let result, _, _):
            return result
        case .invalid(let reason):
            return "Error (invalid_call): \(reason)"
        case .rejected(let reason, _, let code):
            return "Blocked (\(code.rawValue)): \(reason)"
        case .failed(let reason, _):
            return "Tool error: \(reason)"
        }
    }
}

/// What the user is asked to approve: the exact payload that will run, as the
/// broker re-encoded it — never a paraphrase from the model (I2).
struct ApprovalRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let toolName: String
    /// Written by the tool from the validated payload.
    let summary: String
    /// Exactly what will run.
    let payload: JSONValue
    let risk: RiskTier
    /// Why approval is needed, such as "Other people will see this".
    let reason: String
    /// The third-party host the payload goes to, when there is one.
    let destination: String?
    /// The run read content written by others before asking, so the sheet asks
    /// for a closer read.
    let tainted: Bool
    /// Fields the user may change. Empty: the sheet offers no Edit.
    let editableFields: [EditableField]
    /// The payload includes the user's own changes.
    let edited: Bool
    /// Why the user's last change wasn't accepted.
    let problem: String?
}

/// The user's answer to an approval request.
enum ApprovalDecision: Equatable, Sendable {
    case approved
    case denied
    /// The user changed editable fields. This approves nothing: the broker
    /// checks the new payload and asks again with exactly what will run.
    case revised(JSONValue)
    case timedOut
    case cancelled
}

/// One line under an answer saying what really happened, in the tool's own
/// words — so the user sees the truth whatever the model writes.
struct ActionReceipt: Codable, Sendable, Equatable, Identifiable {
    enum Status: String, Codable, Sendable {
        case done, declined, noAnswer, blocked, failed
    }

    var id = UUID()
    let toolName: String
    let summary: String
    let status: Status
    var edited: Bool = false

    var statusLabel: String {
        switch self.status {
        case .done: return edited ? "Done, edited by you" : "Done"
        case .declined: return "You declined"
        case .noAnswer: return "Not approved in time"
        case .blocked: return "Blocked"
        case .failed: return "Failed"
        }
    }
}
