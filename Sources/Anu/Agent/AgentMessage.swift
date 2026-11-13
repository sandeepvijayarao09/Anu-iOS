import Foundation

// MARK: - Message Role

enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case toolCall = "tool_call"
    case toolResult = "tool_result"
    case system
}

// MARK: - Tool Call

struct ToolCallInfo: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let arguments: JSONValue

    init(id: String = UUID().uuidString, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

// MARK: - Agent Message

struct AgentMessage: Identifiable, Sendable, Codable {
    let id: UUID
    let role: MessageRole
    var content: String
    let toolCall: ToolCallInfo?
    let toolResultFor: String? // ID of the tool call this result responds to
    let timestamp: Date
    var isStreaming: Bool
    /// Attached image (multimodal input), shown in the bubble and fed to
    /// vision-capable models.
    let imageData: Data?
    /// What the broker actually did this turn, under the answer: the tools'
    /// own words, never the model's. Nil for older saved messages.
    var receipts: [ActionReceipt]?
    /// A voice note's kind, length and words (never its audio). Its presence
    /// keeps the turn on the device. Nil for every other message.
    var voiceNote: VoiceNoteInfo?

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        toolCall: ToolCallInfo? = nil,
        toolResultFor: String? = nil,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        imageData: Data? = nil,
        receipts: [ActionReceipt]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCall = toolCall
        self.toolResultFor = toolResultFor
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.imageData = imageData
        self.receipts = receipts
    }

    static func user(_ content: String, imageData: Data? = nil) -> AgentMessage {
        AgentMessage(role: .user, content: content, imageData: imageData)
    }

    static func assistant(_ content: String, isStreaming: Bool = false) -> AgentMessage {
        AgentMessage(role: .assistant, content: content, isStreaming: isStreaming)
    }

    static func toolCall(_ info: ToolCallInfo) -> AgentMessage {
        AgentMessage(role: .toolCall, content: "Calling \(info.name)", toolCall: info)
    }

    static func toolResult(content: String, forCallId: String) -> AgentMessage {
        AgentMessage(role: .toolResult, content: content, toolResultFor: forCallId)
    }

    static func system(_ content: String) -> AgentMessage {
        AgentMessage(role: .system, content: content)
    }
}
