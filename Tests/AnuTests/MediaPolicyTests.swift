import XCTest
@testable import Anu

/// MEDIA-1's "asking Gemini by name says it can't" and MEDIA-3's photo
/// retention (Android ADR-075, ADR-091, ADR-094).
@MainActor
final class MediaPolicyTests: XCTestCase {
    private func photo(_ text: String = "A sign") throws -> Data {
        try PictureSecretsTests.png(PictureSecretsTests.render([text], width: 200, height: 150, fontSize: 24))
    }

    private func makeOrch(_ model: any LocalLanguageModel) -> AgentOrchestrator {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mediapolicy-\(UUID().uuidString)", isDirectory: true)
        return AgentOrchestrator(model: model, sessionsDirectory: dir)
    }

    // MARK: Asking Gemini by name

    func testRecognisesAnExplicitAskForGemini() {
        for text in ["Ask Gemini what this is", "use gemini for this", "Gemini, what does this say?",
                     "send this to Gemini", "Hey Gemini describe it", "can you try Google's Gemini on this"] {
            XCTAssertTrue(GeminiByName.isExplicit(text), text)
        }
        for text in ["What is this?", "Is Gemini better than Gemma?", "my sign is gemini", "Tell me about Gemini the constellation"] {
            XCTAssertFalse(GeminiByName.isExplicit(text), text)
        }
    }

    func testAskingGeminiWithAPhotoInViewGetsAPlainNo() async throws {
        let model = RecordingVisionModel(["A sign."])
        let orch = makeOrch(model)
        await orch.run(userMessage: "Ask Gemini what this sign says", attachments: MessageAttachments(photos: [try photo()]))

        XCTAssertEqual(orch.messages.last { $0.role == .assistant }?.content, GeminiByName.photoReply)
        XCTAssertEqual(GeminiByName.photoReply, "Gemini can't see photos, so this stays on your phone.")
        XCTAssertTrue(model.prompts.isEmpty, "not quietly answered on the phone either")
        XCTAssertFalse(orch.messages.contains { $0.role == .toolCall })
    }

    func testAskingGeminiLaterWhileThePhotoIsStillInView() async throws {
        let model = RecordingVisionModel(["A sign."])
        let orch = makeOrch(model)
        await orch.run(userMessage: "What is this?", attachments: MessageAttachments(photos: [try photo()]))
        await orch.run(userMessage: "Use Gemini for a better answer")
        XCTAssertEqual(orch.messages.last { $0.role == .assistant }?.content, GeminiByName.photoReply)
        XCTAssertEqual(model.prompts.count, 1)
    }

    func testAPDFInViewSaysPDFs() {
        let document = AttachedDocument(name: "Lease.pdf", pages: 2, read: 2, text: "Rent is due on the first.", whole: true)
        let history = [AgentMessage(role: .user, content: "Summarize", document: document), .assistant("It's a lease.")]
        XCTAssertEqual(GeminiByName.mediaReply("ask gemini to summarize it", history: history), GeminiByName.documentReply)
        XCTAssertNil(GeminiByName.mediaReply("summarize it again", history: history), "only when Gemini is named")
        XCTAssertNil(GeminiByName.mediaReply("ask gemini", history: [.user("hi"), .assistant("hello")]), "only with media in view")
    }

    // MARK: Photo retention

    func testAPhotoInViewIsKept() throws {
        let history = [AgentMessage(role: .user, content: "What is this?", photos: [try photo()]), .assistant("A sign.")]
        XCTAssertTrue(PhotoRetention.outOfView(history).isEmpty)
    }

    func testAPhotoPastTheWindowIsLetGoInHistoryAndThread() throws {
        let old = AgentMessage(role: .user, content: "What is this?", photos: [try photo(), try photo("B")])
        // Enough later words to push the window past the photo's message.
        var history: [AgentMessage] = [old, .assistant("Two signs.")]
        for i in 0..<20 {
            history.append(.user("Tell me a long story number \(i) " + String(repeating: "and then more words ", count: 20)))
            history.append(.assistant(String(repeating: "Once upon a time ", count: 20)))
        }
        var thread = history
        XCTAssertEqual(PhotoRetention.outOfView(history), [old.id])

        XCTAssertEqual(PhotoRetention.apply(history: &history, messages: &thread), 1)
        for list in [history, thread] {
            let message = try XCTUnwrap(list.first { $0.id == old.id })
            XCTAssertNil(message.photos)
            XCTAssertEqual(message.photosNoLongerKept, 2)
            XCTAssertEqual(message.content, "What is this?", "its words stay")
            XCTAssertFalse(message.carriesMedia)
        }
        XCTAssertEqual(PhotoRetention.line(1), "Photo no longer kept")
        XCTAssertEqual(PhotoRetention.line(2), "2 photos no longer kept")
        XCTAssertEqual(PhotoRetention.apply(history: &history, messages: &thread), 0, "nothing left to let go")
    }

    func testTheViewHoldsFourPicturesSoAnOlderOneIsLetGo() throws {
        let first = AgentMessage(role: .user, content: "One", photos: [try photo()])
        let second = AgentMessage(role: .user, content: "Four more", photos: try (1...4).map { try photo("P\($0)") })
        let history = [first, .assistant("ok"), second, .assistant("ok")]
        XCTAssertEqual(PhotoRetention.outOfView(history), [first.id], "a fifth picture moves the view past the first")
    }

    func testOlderSingleImageMessagesAreLetGoToo() throws {
        let old = AgentMessage.user("Look", imageData: try photo())
        let gone = PhotoRetention.letGo(old)
        XCTAssertNil(gone.imageData)
        XCTAssertEqual(gone.photosNoLongerKept, 1)
        XCTAssertNil(PhotoRetention.letGo(.assistant("hi")).photosNoLongerKept)
    }

    func testTheSavedChatNoLongerHoldsTheLetGoPhoto() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("retention-\(UUID().uuidString)", isDirectory: true)
        let long = String(repeating: "and then a lot more happened in the story ", count: 30)
        let model = RecordingVisionModel(["A sign."] + Array(repeating: long, count: 6))
        let orch = AgentOrchestrator(model: model, sessionsDirectory: dir)
        await orch.run(userMessage: "What is this?", attachments: MessageAttachments(photos: [try photo()]))
        let photoMessage = try XCTUnwrap(orch.messages.first { $0.role == .user })
        XCTAssertEqual(photoMessage.photos?.count, 1)

        for i in 0..<6 { await orch.run(userMessage: "hello, tell me story \(i) " + long) }
        let after = try XCTUnwrap(orch.messages.first { $0.id == photoMessage.id })
        XCTAssertNil(after.photos)
        XCTAssertEqual(after.photosNoLongerKept, 1)

        let saved = orch.activeStore.load()
        let stored = try XCTUnwrap(saved?.messages.first { $0.id == photoMessage.id })
        XCTAssertNil(stored.photos, "deleted from the encrypted chat store, not only hidden")
        XCTAssertEqual(stored.photosNoLongerKept, 1)
    }
}
