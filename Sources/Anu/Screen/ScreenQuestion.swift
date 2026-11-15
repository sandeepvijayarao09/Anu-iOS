import AppIntents
import Foundation
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
import SwiftUI
#endif

// Questions about the screen (Android ADR-083, ADR-108), in the closest form
// iOS allows. iOS gives apps no way to see another app's screen, so Anu asks
// about a screenshot the user hands it: shared into Anu with the share sheet
// (AnuShare), picked from the photo library's Screenshots with "Ask About My
// Screen", or passed by a shortcut (Shortcuts' own "Take Screenshot", then
// "Ask Anu About a Screenshot", which can sit on the Action button or Back
// Tap). Every path ends in the composer, where the picture is readied like
// any screen: Vision reads its text on the phone and the secrets in it (codes,
// card numbers, passwords) are blacked out before any model sees it
// (`ScreenSecrets`), and the codes found are kept with the turn in memory only.

enum ScreenQuestion {
    /// One-shot flag: open the screenshot picker when the chat appears.
    static let pendingPickerKey = "pending_screen_picker"
    /// One-shot question to put in the composer with a handed-over screenshot.
    static let pendingQuestionKey = "pending_screen_question"
    static let defaultQuestion = "What's on this screen?"
    /// The hand-off name that marks a picture as a screen ("Screenshot …"),
    /// so it's masked even when its shape or metadata don't say so.
    static let handOffName = "Screenshot.png"

    static func requestPicker(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: pendingPickerKey)
    }

    static func consumePicker(_ defaults: UserDefaults = .standard) -> Bool {
        guard defaults.bool(forKey: pendingPickerKey) else { return false }
        defaults.set(false, forKey: pendingPickerKey)
        return true
    }

    static func consumeQuestion(_ defaults: UserDefaults = .standard) -> String? {
        guard let question = defaults.string(forKey: pendingQuestionKey) else { return nil }
        defaults.removeObject(forKey: pendingQuestionKey)
        return question
    }

    /// Hands a screenshot to the chat's composer through the App Group inbox,
    /// the same way the share extension does. Nothing is sent anywhere.
    @discardableResult
    static func handOver(_ data: Data, question: String?, inbox: InboxStore = InboxStore(),
                         directory: URL = SharedMedia.directory,
                         defaults: UserDefaults = .standard) -> Bool {
        guard let name = SharedMedia.put(data, fileName: handOffName, directory: directory) else { return false }
        inbox.enqueue(attachments: [name])
        let asked = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        defaults.set(asked.isEmpty ? defaultQuestion : asked, forKey: pendingQuestionKey)
        return true
    }
}

/// "Ask About My Screen": opens Anu with the photo picker on Screenshots.
/// Not in `AnuShortcuts` (at Apple's cap of 10); it's a Shortcuts action.
struct AskAboutScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask About My Screen"
    static let description = IntentDescription("Open Anu with your screenshots, to ask about one. Secrets on the screen are blacked out on this device before Anu reads it.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ScreenQuestion.requestPicker()
        return .result()
    }
}

/// "Ask Anu About a Screenshot": takes a picture from a shortcut (such as
/// Shortcuts' "Take Screenshot") and opens Anu with it in the composer.
struct AskAboutScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Anu About a Screenshot"
    static let description = IntentDescription("Opens Anu with a screenshot ready to ask about, such as one from “Take Screenshot”. Secrets on it are blacked out on this device first.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Screenshot", supportedTypeIdentifiers: ["public.image"])
    var screenshot: IntentFile

    @Parameter(title: "Question", requestValueDialog: "What do you want to know about it?")
    var question: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        guard ScreenQuestion.handOver(screenshot.data, question: question) else {
            throw ToolError.executionFailed("Anu couldn't take that screenshot.")
        }
        NotificationCenter.default.post(name: .anuInboxUpdated, object: nil)
        return .result()
    }
}

#if os(iOS)
/// The chat's side of screen questions: the Screenshots picker that "Ask
/// About My Screen" opens (from the composer's menu or the App Intent), and
/// the question that comes with a handed-over screenshot.
struct ScreenQuestionModifier: ViewModifier {
    @ObservedObject var composer: AttachmentComposer
    @ObservedObject var sharedInbox: SharedAttachmentInbox
    @Binding var showPicker: Bool
    @Binding var text: String
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $showPicker, selection: $composer.screenPickerItems,
                          maxSelectionCount: 1, matching: .screenshots)
            .onChange(of: composer.screenPickerItems) { _, items in
                guard !items.isEmpty else { return }
                composer.loadPickedScreens()
                if text.isEmpty { text = ScreenQuestion.defaultQuestion }
            }
            .onAppear { consume() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { consume() } }
            .onChange(of: sharedInbox.items.count) { _, _ in
                if let question = ScreenQuestion.consumeQuestion(), text.isEmpty { text = question }
            }
    }

    private func consume() {
        if ScreenQuestion.consumePicker() { showPicker = true }
    }
}
#endif
