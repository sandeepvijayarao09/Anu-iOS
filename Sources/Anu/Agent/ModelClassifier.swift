import Foundation

/// Which model/path should handle a prompt.
enum ModelRoute: Equatable, Sendable {
    /// Local model, lightweight friendly persona — fastest, no tools.
    case onDeviceChat
    /// Local model driving the full ReAct tool loop.
    case onDeviceAgent
    /// Send straight to the cloud model (Gemini) — for heavy generation
    /// when an API key is configured.
    case cloudEscalate

    var displayName: String {
        switch self {
        case .onDeviceChat: return "on-device (chat)"
        case .onDeviceAgent: return "on-device (agent + tools)"
        case .cloudEscalate: return "cloud (Gemini)"
        }
    }
}

/// Decides which model handles a classified task.
///
/// Principles:
/// - Privacy & latency first: everything stays on-device unless the task
///   clearly benefits from the bigger cloud model AND a key is configured.
/// - Tools require the agent loop; conversation does not.
/// - Low classification confidence falls back to the agent loop (it can
///   handle anything, just slower).
enum ModelClassifier {

    static let confidenceFloor = 0.45

    static func route(
        task: TaskClassification,
        cloudAvailable: Bool,
        webSearchAvailable: Bool
    ) -> ModelRoute {
        // Uncertain classification → the conversational path, NOT the agent.
        // The tool-heavy ReAct prompt is long and structurally complex; handing
        // it a short/ambiguous query (where the classifier had no real signal)
        // reliably degenerates the small on-device model into repeated role-
        // label salad ("Anu: user: tool_for: …") with no usable answer. Chat
        // degrades gracefully — the model still answers from its own knowledge,
        // just without tools — matching the "default to chat" philosophy the
        // heuristic MessageRouter already documents.
        guard task.confidence >= confidenceFloor else { return .onDeviceChat }

        switch task.type {
        case .casualChat, .generalQA:
            return .onDeviceChat
        case .math:
            // The calculator tool is always available (no key needed) and math
            // prompts are concrete, so the agent loop is both useful and safe.
            return .onDeviceAgent
        case .webInfo:
            // Web questions only benefit from the agent loop when something can
            // actually fetch fresh info — a configured web-search provider or
            // the cloud. With neither, the loop just spins on a tool that
            // reports "not configured" while a short query degenerates the
            // model. Answer conversationally instead (same graceful fallback as
            // codeGen/longWriting below).
            return (webSearchAvailable || cloudAvailable) ? .onDeviceAgent : .onDeviceChat
        case .codeGen, .longWriting:
            // Heavy generation is where the cloud model earns its latency;
            // without a key the local model handles it conversationally.
            return cloudAvailable ? .cloudEscalate : .onDeviceChat
        }
    }

    /// True when any cloud provider (private compute server or Gemini) is
    /// configured to handle escalation.
    static var cloudAvailable: Bool {
        CloudProvider.resolved() != nil
    }

    /// True when a web-search provider is configured (a Brave Search API key in
    /// the Keychain). Without it the `web_search` tool only returns a
    /// "not configured" message, so routing web questions through the agent
    /// loop buys nothing — see `route(task:cloudAvailable:webSearchAvailable:)`.
    static var webSearchAvailable: Bool {
        !(KeychainStore.shared.string(forKey: "search_api_key") ?? "").isEmpty
    }

    /// Questions whose answer depends on a device tool (clock, calendar,
    /// reminders, contacts). These must use the agent path so the tool runs —
    /// the tool-less chat path would let the model invent an answer (e.g. the
    /// wrong time). Kept narrow to avoid pulling casual chat onto the slow path.
    static func needsDeviceTool(_ message: String) -> Bool {
        let lower = message.lowercased()
        let markers = [
            "what time", "what's the time", "what is the time", "current time",
            "the time", "time is it", "what day", "what's the date",
            "what is the date", "today's date", "what's today", "date today",
            "remind me", "reminder", "my calendar", "my schedule", "my events",
            "on my calendar", "set an alarm", "my contacts", "phone number for",
        ]
        return lower.containsAnyWord(markers)
    }
}
