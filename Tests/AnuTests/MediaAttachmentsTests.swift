import XCTest
import CoreGraphics
import os
@testable import Anu

/// A test model that streams its scripted answers word by word and records the
/// pictures each call carried, like QueuedMockModel for vision turns.
final class RecordingVisionModel: LocalLanguageModel, Sendable {
    nonisolated let modelName = "Recording Vision Mock"

    private struct State {
        var responses: [String]
        var prompts: [String] = []
        var imageCounts: [Int] = []
        var resets = 0
    }
    private let state: OSAllocatedUnfairLock<State>

    init(_ responses: [String]) { state = OSAllocatedUnfairLock(initialState: State(responses: responses)) }

    var prompts: [String] { state.withLock { $0.prompts } }
    var imageCounts: [Int] { state.withLock { $0.imageCounts } }

    func load() async throws {}
    func resetSession() async { state.withLock { $0.resets += 1 } }

    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String> {
        try await generate(prompt: prompt, images: [], config: config)
    }

    func generate(prompt: String, images: [CGImage], config: GenerationConfig) async throws -> AsyncStream<String> {
        let next = state.withLock { s -> String in
            s.prompts.append(prompt)
            s.imageCounts.append(images.count)
            return s.responses.isEmpty ? "Mock fallback answer" : s.responses.removeFirst()
        }
        let words = next.components(separatedBy: " ")
        return AsyncStream { continuation in
            for (i, word) in words.enumerated() { continuation.yield(i == 0 ? word : " " + word) }
            continuation.finish()
        }
    }
}

/// Several photos per message (ADR-094), the cloud kept out (MEDIA-1), and
/// answers about a photo masked (ADR-082).
@MainActor
final class MediaAttachmentsTests: XCTestCase {
    private func makeOrch(_ model: any LocalLanguageModel) -> AgentOrchestrator {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("media-\(UUID().uuidString)", isDirectory: true)
        return AgentOrchestrator(model: model, sessionsDirectory: dir)
    }

    private func photo(_ text: String = "A sign") throws -> Data {
        try PictureSecretsTests.png(PictureSecretsTests.render([text], width: 400, height: 300, fontSize: 30))
    }

    func testAMessageTakesAtMostFourPhotos() throws {
        var attachments = MessageAttachments()
        let six = try (1...6).map { try photo("Photo \($0)") }
        XCTAssertEqual(attachments.add(photos: Array(six.prefix(3))), 0)
        XCTAssertEqual(attachments.add(photos: Array(six.suffix(3))), 2, "past four the rest are left out")
        XCTAssertEqual(attachments.photos.count, 4)
        XCTAssertEqual(attachments.photosLeft, 0)
        attachments.removePhoto(at: 0)
        XCTAssertEqual(attachments.photosLeft, 1)
    }

    func testTheModelsViewHoldsAtMostFourPictures() {
        XCTAssertTrue(PictureBudget.fitsInView(held: 0, adding: 4))
        XCTAssertTrue(PictureBudget.fitsInView(held: 2, adding: 2))
        XCTAssertFalse(PictureBudget.fitsInView(held: 1, adding: 4), "a fifth starts the view afresh")
    }

    func testFourPhotosReachTheModelAndTheTurnStaysOnThePhone() async throws {
        let model = RecordingVisionModel(["Four numbered pictures."])
        let orch = makeOrch(model)
        let six = try (1...6).map { try photo("Photo \($0)") }
        await orch.run(userMessage: "What are these?", attachments: MessageAttachments(photos: six))

        XCTAssertEqual(model.imageCounts, [4], "at most four pictures in the model's view")
        let user = try XCTUnwrap(orch.messages.first { $0.role == .user })
        XCTAssertEqual(user.photos?.count, 4)
        XCTAssertTrue(orch.reasoningSteps.contains { $0.action?.contains("On-Device") == true || $0.thought.contains("on-device only") })
        XCTAssertFalse(orch.messages.contains { $0.role == .toolCall }, "no tools, no cloud")
        XCTAssertEqual(orch.messages.last { $0.role == .assistant }?.content, "Four numbered pictures.")
    }

    func testOlderSingleImageEntryPointStillWorks() async throws {
        let model = RecordingVisionModel(["A sign."])
        let orch = makeOrch(model)
        await orch.run(userMessage: "Read this", imageData: try photo())
        XCTAssertEqual(model.imageCounts, [1])
    }

    func testAnswerAboutAPhotoIsMaskedBeforeItIsShownOrSaved() async throws {
        let model = RecordingVisionModel(["Your code is 483920. It expires in ten minutes."])
        let orch = makeOrch(model)
        await orch.run(userMessage: "What does this say?", attachments: MessageAttachments(photos: [try photo()]))

        let masked = "Your code is \(OneTimeCodes.mask). It expires in ten minutes."
        XCTAssertEqual(orch.messages.last { $0.role == .assistant }?.content, masked)
        XCTAssertEqual(orch.conversationHistory.last?.content, masked, "the saved chat keeps only the masked answer")
        XCTAssertFalse(orch.messages.contains { $0.content.contains("483920") })
    }

    func testCloudCallsAreRefusedWhileAPhotoIsInView() async throws {
        let orch = makeOrch(RecordingVisionModel(["A sign."]))
        await orch.run(userMessage: "What is this?", attachments: MessageAttachments(photos: [try photo()]))
        XCTAssertTrue(orch.hasMediaInView)

        let escalate = ToolCallInfo(name: "escalate_to_gemini", arguments: .object(["task": .string("describe it")]))
        let result = await orch.gatedToolResult(escalate)
        XCTAssertEqual(result, AgentOrchestrator.mediaStaysOnPhone)
    }

    func testPlainChatHasNoMediaInView() async {
        let orch = makeOrch(RecordingVisionModel(["Hello!"]))
        await orch.run(userMessage: "hello there")
        XCTAssertFalse(orch.hasMediaInView)
    }

    func testPhotosWithNoWordsAskForWhatTheyShow() throws {
        let message = AgentMessage(role: .user, content: "", photos: [try photo(), try photo()])
        let view = AgentOrchestrator.modelView([message, .assistant("ok"), .user("thanks")])
        XCTAssertTrue(view[0].content.contains("2 photos with no words"), view[0].content)
        XCTAssertEqual(view[0].id, message.id, "ids are kept")
        XCTAssertEqual(view[2].content, "thanks")
    }

    func testAPhotoTurnIsNeverRemembered() async throws {
        let before = MemoryStore.shared.notes.count
        let orch = makeOrch(RecordingVisionModel(["A sticky note."]))
        await orch.run(userMessage: "remember this wifi password", attachments: MessageAttachments(photos: [try photo()]))
        XCTAssertEqual(MemoryStore.shared.notes.count, before, "photos never reach memory")
    }

    func testPhotosAndDocumentSurviveTheEncryptedStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        let store = ConversationStore(directory: dir)
        let document = AttachedDocument(name: "Lease.pdf", pages: 12, read: 12, text: "Rent is 1,200.", whole: true)
        let message = AgentMessage(role: .user, content: "What's the rent?", photos: [try photo()], document: document)
        store.save(messages: [message], history: [message])
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.messages.first?.photos?.count, 1)
        XCTAssertEqual(loaded.messages.first?.document, document)
    }
}
