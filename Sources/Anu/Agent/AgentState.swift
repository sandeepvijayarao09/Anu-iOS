import Foundation
import Observation

// MARK: - Agent Status

enum AgentStatus: Sendable, Equatable {
    case idle
    case planning
    case thinking
    case callingTool(String)
    case escalating
    case streaming
    case verifying
    case error(String)

    var displayText: String {
        switch self {
        case .idle: return "Ready"
        case .planning: return "Planning..."
        case .thinking: return "Thinking..."
        case .callingTool(let name): return "Using \(name)..."
        case .escalating: return "Escalating to Gemini..."
        case .streaming: return "Generating..."
        case .verifying: return "Reviewing..."
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var iconName: String {
        switch self {
        case .idle: return "circle.fill"
        case .planning: return "list.bullet.clipboard"
        case .thinking: return "brain"
        case .callingTool: return "wrench.fill"
        case .escalating: return "arrow.up.circle.fill"
        case .streaming: return "waveform"
        case .verifying: return "checkmark.seal"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var color: String {
        switch self {
        case .idle: return "green"
        case .planning: return "blue"
        case .thinking: return "blue"
        case .callingTool: return "orange"
        case .escalating: return "purple"
        case .streaming: return "blue"
        case .verifying: return "blue"
        case .error: return "red"
        }
    }
}

// MARK: - Model Load State

/// Connection state of the active brain. Surfaced in Settings → Model (the
/// "Model status" section) instead of as chat "disclaimer" messages on the
/// home screen.
enum ModelLoadState: Sendable, Equatable {
    case loading
    case ready
    case failed(String)

    var summary: String {
        switch self {
        case .loading: return "Connecting…"
        case .ready: return "Connected"
        case .failed: return "Unavailable"
        }
    }
}

// MARK: - Reasoning Step

/// What a reasoning step represents — drives the glass-box timeline's node
/// icon/color so plan/specialist/tool/critic stages read at a glance. Purely
/// presentational; defaulting to `.thought` keeps every existing call site valid.
enum ReasoningStepKind: Sendable, Equatable {
    case route          // task classification → model route
    case memory         // personalization / memory grounding
    case plan           // planner output
    case specialistStep // a plan step run by a specialist sub-agent
    case tool           // a tool call + observation
    case critic         // critic verdict
    case final          // final answer
    case thought        // generic single-shot reasoning

    var iconName: String {
        switch self {
        case .route: return "arrow.triangle.branch"
        case .memory: return "brain.head.profile"
        case .plan: return "list.bullet.clipboard"
        case .specialistStep: return "person.fill.badge.plus"
        case .tool: return "wrench.and.screwdriver.fill"
        case .critic: return "checkmark.seal"
        case .final: return "flag.checkered"
        case .thought: return "bubble.left"
        }
    }

    /// SwiftUI color name resolved by the view (kept as a String like
    /// `AgentStatus.color` so this type stays UI-framework-free).
    var colorName: String {
        switch self {
        case .route: return "indigo"
        case .memory: return "teal"
        case .plan: return "blue"
        case .specialistStep: return "purple"
        case .tool: return "orange"
        case .critic: return "green"
        case .final: return "green"
        case .thought: return "blue"
        }
    }
}

// MARK: - Pending tool confirmation

/// An outward action awaiting the user's approval — drives the chat alert.
struct PendingToolConfirmation: Identifiable, Equatable, Sendable {
    let id: UUID
    let toolName: String
    let summary: String
    init(id: UUID = UUID(), toolName: String, summary: String) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
    }
}

struct ReasoningStep: Identifiable, Sendable {
    let id = UUID()
    let iteration: Int
    let thought: String
    let action: String?
    let observation: String?
    let timestamp: Date
    let kind: ReasoningStepKind
    /// Specialist name for `.specialistStep` rows (e.g. "researcher"); nil otherwise.
    let specialist: String?

    init(
        iteration: Int,
        thought: String,
        action: String? = nil,
        observation: String? = nil,
        kind: ReasoningStepKind = .thought,
        specialist: String? = nil
    ) {
        self.iteration = iteration
        self.thought = thought
        self.action = action
        self.observation = observation
        self.timestamp = Date()
        self.kind = kind
        self.specialist = specialist
    }
}

// (The old AgentState observable class was removed — AgentOrchestrator is
// the single source of truth for UI state. AgentStatus and ReasoningStep
// above are the shared value types.)
