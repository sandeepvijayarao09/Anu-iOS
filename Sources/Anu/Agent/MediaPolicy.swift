import Foundation

// Two media rules from Anu for Android (ARCHITECTURE §11 MEDIA-1 and MEDIA-3):
// - Asking Gemini by name with a photo or PDF in view says it can't, rather
//   than quietly answering on the phone (ADR-075).
// - A photo is kept only while its message is in the model's view. The view
//   only moves forward, so once it passes a photo's message the model never
//   sees it again: the photo is deleted from the saved chat and the thread
//   shows "Photo no longer kept" in its place (ADR-091, ADR-094). The user's
//   original stays in their library or the app that shared it.

/// Whether a message asks for Gemini by name.
enum GeminiByName {
    private static let pattern = try! NSRegularExpression(pattern: // swiftlint:disable:this force_try
        #"(^\W*(hey\s+|ok\s+)?gemini\b)|\b(ask|use|using|with|via|through|try|let|have|get|send(\s+(this|it|that))?\s+to|pass(\s+(this|it|that))?\s+to|switch\s+to)\s+(google'?s?\s+)?gemini\b|\bgemini,?\s+(please|can you|could you|what|tell|describe|read|summari[sz]e|look)"#,
        options: [.caseInsensitive])

    static func isExplicit(_ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The plain reply when Gemini is asked for with media in view, or nil
    /// when the message doesn't name Gemini or nothing is in view.
    static func mediaReply(_ text: String, history: [AgentMessage]) -> String? {
        guard isExplicit(text) else { return nil }
        let view = ConversationWindow.windowed(AgentOrchestrator.modelView(history)).filter(\.carriesMedia)
        guard !view.isEmpty else { return nil }
        let photos = view.contains { !$0.pictures.isEmpty && $0.document?.pictures != true }
        return photos ? photoReply : documentReply
    }

    static let photoReply = "Gemini can't see photos, so this stays on your phone."
    static let documentReply = "Gemini can't see PDFs, so this stays on your phone."
}

/// MEDIA-3: photos let go once the model's view has passed their message.
enum PhotoRetention {
    /// The ids of user messages that still hold photos but are out of the
    /// model's view of `history`.
    /// The view holds at most four pictures (ADR-094), so counting back from
    /// the newest, a message whose photos would pass four is out of it too.
    /// This never lets go of a picture the engine still holds: the engine starts
    /// afresh at the fifth, which drops at least as many.
    static func outOfView(_ history: [AgentMessage]) -> Set<UUID> {
        let window = ConversationWindow.windowed(AgentOrchestrator.modelView(history))
        var inView = Set<UUID>()
        var pictures = 0
        var full = false
        for message in window.reversed() {
            let count = message.role == .user ? message.pictures.count : 0
            if count > 0 {
                if full || pictures + count > PictureBudget.maxInView { full = true; continue }
                pictures += count
            }
            inView.insert(message.id)
        }
        return Set(history.filter { $0.role == .user && !$0.pictures.isEmpty && !inView.contains($0.id) }.map(\.id))
    }

    /// `message` without its photos, marked for the thread.
    static func letGo(_ message: AgentMessage) -> AgentMessage {
        let count = message.pictures.count
        guard count > 0 else { return message }
        var copy = message
        copy.photos = nil
        copy.imageData = nil
        copy.photosNoLongerKept = (message.photosNoLongerKept ?? 0) + count
        return copy
    }

    /// Lets go of every photo out of view, in both the history and the thread.
    /// Returns how many messages changed.
    @discardableResult
    static func apply(history: inout [AgentMessage], messages: inout [AgentMessage]) -> Int {
        let gone = outOfView(history)
        guard !gone.isEmpty else { return 0 }
        history = history.map { gone.contains($0.id) ? letGo($0) : $0 }
        messages = messages.map { gone.contains($0.id) ? letGo($0) : $0 }
        return gone.count
    }

    /// The thread's line for a message whose photos were let go.
    static func line(_ count: Int) -> String {
        count == 1 ? "Photo no longer kept" : "\(count) photos no longer kept"
    }

    static func accessibilityLine(_ count: Int) -> String {
        count == 1 ? "Photo you shared, no longer kept" : "\(count) photos you shared, no longer kept"
    }
}

extension AgentOrchestrator {
    /// Lets go of photos the model's view has passed (MEDIA-3). Called once a
    /// turn has settled, before the chat is saved.
    func releasePhotosOutOfView() {
        PhotoRetention.apply(history: &conversationHistory, messages: &messages)
    }
}
