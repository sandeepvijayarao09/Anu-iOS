import AppIntents
import Foundation

/// "Brief me": opens Anu on today's Daily Brief, made then on the device.
/// A Shortcuts action and a Siri phrase through Shortcuts; deliberately NOT in
/// `AnuShortcuts`, which is at Apple's cap of 10 App Shortcuts.
struct BriefMeIntent: AppIntent {
    static let title: LocalizedStringResource = "Brief Me"
    static let description = IntentDescription("Open Anu's Daily Brief: today's calendar, reminders, and what Anu remembers that bears on today, made on this device.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DailyBriefRouter.shared.open()
        return .result()
    }
}
