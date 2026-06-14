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
        cloudAvailable: Bool
    ) -> ModelRoute {
        guard task.confidence >= confidenceFloor else { return .onDeviceAgent }

        switch task.type {
        case .casualChat, .generalQA:
            return .onDeviceChat
        case .math, .webInfo:
            return .onDeviceAgent
        case .codeGen, .longWriting:
            // Heavy generation is where the cloud model earns its latency;
            // without a key the local model handles it conversationally.
            return cloudAvailable ? .cloudEscalate : .onDeviceChat
        }
    }

    static var cloudAvailable: Bool {
        !(KeychainStore.shared.string(forKey: "gemini_api_key") ?? "").isEmpty
    }
}
