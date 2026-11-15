import AppIntents
import Foundation

// MARK: - Opening things from Siri and Spotlight (A5, A7)

/// "Open <chat> in Anu". Also what runs when you tap a chat in Spotlight.
struct OpenChatIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Chat"
    static let description = IntentDescription("Open one of your Anu chats.")

    @Parameter(title: "Chat")
    var target: ChatEntity

    init() {}
    init(target: ChatEntity) { self.target = target }

    @MainActor
    func perform() async throws -> some IntentResult {
        await AnuRoutes.openChat(target.id)
        return .result()
    }
}

/// Opens the Memory screen. What runs when you tap a memory in Spotlight.
struct OpenMemoryIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Memory"
    static let description = IntentDescription("Open what Anu remembers, at this memory.")

    @Parameter(title: "Memory")
    var target: MemoryFactEntity

    init() {}
    init(target: MemoryFactEntity) { self.target = target }

    @MainActor
    func perform() async throws -> some IntentResult {
        AnuRoutes.request(.memory)
        return .result()
    }
}

/// "Record a voice note in Anu": opens the chat and starts a voice note.
struct RecordVoiceNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Record a Voice Note"
    static let description = IntentDescription("Open Anu and start recording a voice note to send to it.")
    static let openAppWhenRun: Bool = true
    /// `openAppWhenRun` is deprecated from iOS 26; it stays for iOS 17–25.
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    /// One-shot flag the chat consumes when the app becomes active.
    static let pendingKey = "pending_voice_note"

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: Self.pendingKey)
        return .result()
    }

    /// Reads and clears the flag.
    static func consumePending(_ defaults: UserDefaults = .standard) -> Bool {
        guard defaults.bool(forKey: pendingKey) else { return false }
        defaults.set(false, forKey: pendingKey)
        return true
    }
}

// MARK: - Routes the UI picks up

extension Notification.Name {
    /// An intent asked the UI to show a screen (`AnuRoutes.pending`).
    static let anuRouteRequested = Notification.Name("com.anu.routeRequested")
}

/// One-shot hand-offs from intents to the UI — the same pattern as
/// `StartVoiceIntent` — for screens that aren't the chat.
enum AnuRoutes {
    enum Route: String {
        case memory
        /// The chat list, with `SearchAnuIntentKeys.pendingSearch` applied.
        case search
    }

    static let pendingKey = "anu.pendingRoute"

    static func request(_ route: Route, defaults: UserDefaults = .standard) {
        defaults.set(route.rawValue, forKey: pendingKey)
        NotificationCenter.default.post(name: .anuRouteRequested, object: nil)
    }

    /// Reads and clears the pending route.
    static func consume(_ defaults: UserDefaults = .standard) -> Route? {
        guard let raw = defaults.string(forKey: pendingKey) else { return nil }
        defaults.removeObject(forKey: pendingKey)
        return Route(rawValue: raw)
    }

    /// Switches to a chat and brings the chat forward. Incognito and isolated
    /// chats can't be opened this way (they're never exposed as entities).
    @MainActor
    static func openChat(_ id: UUID) async {
        let orchestrator = AgentOrchestrator.shared
        await orchestrator.setup()
        guard let session = orchestrator.sessions.first(where: { $0.id == id }),
              AnuIndexPolicy.isShareable(session) else { return }
        await orchestrator.switchSession(to: id)
        NotificationCenter.default.post(name: .anuShowChat, object: nil)
    }
}
