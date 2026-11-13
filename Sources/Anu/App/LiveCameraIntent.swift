import AppIntents
import Foundation

#if os(iOS)
/// "Open Live Camera in Anu": opens the app on the live camera page. Listed in
/// the Shortcuts app as an action; it is deliberately NOT in `AnuShortcuts`,
/// which is already at Apple's cap of 10 App Shortcuts.
struct OpenLiveCameraIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Live Camera"
    static let description = IntentDescription("Open Anu's live camera to find things around you and ask about them, on this phone.")
    static let openAppWhenRun: Bool = true

    /// One-shot flag the chat consumes when the app becomes active.
    static let pendingKey = "pending_live_camera"

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
#endif
