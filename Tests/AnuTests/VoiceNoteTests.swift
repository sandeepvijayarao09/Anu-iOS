import XCTest
import CryptoKit
import CoreGraphics
@testable import Anu

/// Voice notes (Android ADR-078): the audio container, splitting, cleanup,
/// the on-device transcriber chain, the composer's lifecycle, the shared
/// recording hand-off, and the rule that a voice note never reaches the cloud.
@MainActor
final class VoiceNoteTests: XCTestCase {

    private var dir: URL!
    private let keys = StaticDataKey(key: SymmetricKey(size: .bits256))

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func recording(seconds: Double, rate: Int = 16_000, amplitude: Int16 = 3_000, shared: Bool = false) -> VoiceRecording {
        let count = Int(seconds * Double(rate))
        let samples = (0..<count).map { i in Int16(Double(amplitude) * sin(Double(i) * 0.05)) }
        return VoiceRecording(pcm: VoiceRecording.pcmData(samples), sampleRate: rate, shared: shared)
    }

    // MARK: Audio

    func testWAVRoundTrip() throws {
        let note = recording(seconds: 0.5)
        let wav = note.wav
        XCTAssertEqual(wav.count, 44 + note.pcm.count)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        let decoded = try XCTUnwrap(WAV.decode(wav))
        XCTAssertEqual(decoded.sampleRate, 16_000)
        XCTAssertEqual(decoded.pcm, note.pcm)
        XCTAssertNil(WAV.decode(Data("not audio".utf8)))
    }

    func testSamplesRoundTripAndSeconds() {
        let samples: [Int16] = [0, 1, -1, .max, .min, 1234]
        let note = VoiceRecording(pcm: VoiceRecording.pcmData(samples))
        XCTAssertEqual(note.samples, samples)
        XCTAssertEqual(recording(seconds: 17).seconds, 17)
        XCTAssertEqual(VoiceNoteFormat.duration(17), "0:17")
        XCTAssertEqual(VoiceNoteFormat.duration(245), "4:05")
    }

    func testPiecesCutAtTheQuietestMomentBeforeEachLimit() {
        let rate = 100 // 100 samples a second keeps the test fast
        var samples = [Int16](repeating: 5_000, count: rate * 70)
        // A pause at 27 s and another at 50 s.
        for k in (27 * rate)..<(27 * rate + 30) { samples[k] = 0 }
        for k in (50 * rate)..<(50 * rate + 30) { samples[k] = 0 }
        let pieces = VoiceNoteTranscript.pieces(samples, sampleRate: rate, maxSeconds: 30)
        XCTAssertEqual(pieces.count, 3)
        XCTAssertEqual(pieces.first?.lowerBound, 0)
        XCTAssertEqual(pieces.last?.upperBound, samples.count)
        XCTAssertTrue((27 * rate...27 * rate + 30).contains(pieces[0].upperBound), "first cut in the 27 s pause, got \(pieces[0].upperBound)")
        XCTAssertTrue((50 * rate...50 * rate + 30).contains(pieces[1].upperBound), "second cut in the 50 s pause, got \(pieces[1].upperBound)")
        for piece in pieces { XCTAssertLessThanOrEqual(piece.count, 30 * rate) }
        for (a, b) in zip(pieces, pieces.dropFirst()) { XCTAssertEqual(a.upperBound, b.lowerBound) }
        XCTAssertEqual(VoiceNoteTranscript.pieces([1, 2, 3], sampleRate: rate), [0..<3])
        XCTAssertEqual(VoiceNoteTranscript.pieces([], sampleRate: rate), [])
    }

    func testTranscriptCleanup() {
        XCTAssertEqual(VoiceNoteTranscript.clean("  [no speech] "), "")
        XCTAssertEqual(VoiceNoteTranscript.clean("[No Speech]."), "")
        XCTAssertEqual(VoiceNoteTranscript.clean("\"Pick up milk tomorrow\""), "Pick up milk tomorrow")
        XCTAssertEqual(VoiceNoteTranscript.clean("Transcript: call Maya at five"), "call Maya at five")
        XCTAssertEqual(VoiceNoteTranscript.clean("Remind me at 6"), "Remind me at 6")
    }

    // MARK: Transcriber chain

    private struct Fake: VoiceNoteTranscribing {
        let engineName: String
        let result: Result<String, TranscriptionError>
        func transcribe(_ recording: VoiceRecording) async throws -> String { try result.get() }
    }

    func testChainFallsBackWhenAnEngineCantRun() async throws {
        let chain = TranscriberChain(engines: [
            Fake(engineName: "Gemma", result: .failure(.unavailable("The loaded model can't hear audio."))),
            Fake(engineName: "Apple", result: .success(" \"buy eggs\" ")),
        ])
        let out = try await chain.transcribe(recording(seconds: 1))
        XCTAssertEqual(out.text, "buy eggs")
        XCTAssertEqual(out.engine, "Apple")
    }

    func testChainStopsOnARealFailureAndReportsWhenNothingCanRun() async {
        let failing = TranscriberChain(engines: [
            Fake(engineName: "Gemma", result: .failure(.failed("decoder crashed"))),
            Fake(engineName: "Apple", result: .success("never reached")),
        ])
        do { _ = try await failing.transcribe(recording(seconds: 1)); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? TranscriptionError, .failed("decoder crashed")) }

        let none = TranscriberChain(engines: [Fake(engineName: "A", result: .failure(.unavailable("no recognizer")))])
        do { _ = try await none.transcribe(recording(seconds: 1)); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? TranscriptionError, .unavailable("no recognizer")) }
    }

    /// A model that hears, recording each piece it was given.
    private actor HearingModel: LocalLanguageModel, AudioTranscribingModel {
        nonisolated let modelName = "Gemma 4 E4B test"
        private(set) var pieces: [Data] = []
        func load() async throws {}
        func generate(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String> { AsyncStream { $0.finish() } }
        func generate(prompt: String, image: CGImage?, config: GenerationConfig) async throws -> AsyncStream<String> { AsyncStream { $0.finish() } }
        func resetSession() async {}
        func canTranscribeAudio() async -> Bool { true }
        func transcribeAudio(wav: Data, prompt: String) async throws -> String {
            pieces.append(wav)
            return pieces.count == 1 ? "first part" : "[no speech]"
        }
    }

    func testGemmaTranscriberSendsWAVPiecesAndJoinsTheirWords() async throws {
        let model = HearingModel()
        let gemma = GemmaAudioTranscriber(model: { model })
        let words = try await gemma.transcribe(recording(seconds: 45, rate: 1_000))
        XCTAssertEqual(words, "first part")
        let pieces = await model.pieces
        XCTAssertEqual(pieces.count, 2)
        XCTAssertNotNil(WAV.decode(pieces[0]))
    }

    func testGemmaTranscriberIsUnavailableForAModelThatCantHear() async {
        let gemma = GemmaAudioTranscriber(model: { ScriptedModel() })
        do { _ = try await gemma.transcribe(recording(seconds: 1)); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? TranscriptionError, .unavailable("The loaded model can't hear audio.")) }
    }

    // MARK: Composer lifecycle

    private func controller(_ transcribe: @escaping (VoiceRecording) async throws -> VoiceNoteTranscription) -> VoiceNoteController {
        VoiceNoteController(
            store: PendingVoiceNoteStore(url: dir.appendingPathComponent("pending.anuaudio"), keys: keys),
            drop: SharedVoiceNoteDrop(directory: dir.appendingPathComponent("drop"), keys: keys),
            transcribe: transcribe)
    }

    /// Audio File in the attach menu (AI Edge Gallery's Audio Scribe).
    func testAPickedAudioFileBecomesTheComposersRecording() throws {
        let notes = controller { _ in VoiceNoteTranscription(text: "x", engine: "Apple", millis: 1) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("meeting.wav")
        try recording(seconds: 3).wav.write(to: wav)
        notes.importFile(.success(wav))
        XCTAssertEqual(notes.phase, .ready)
        XCTAssertEqual(notes.pending?.seconds, 3)
        XCTAssertEqual(notes.pending?.shared, true, "a file can hold other people's words")
        XCTAssertEqual(notes.pendingTitle, "Audio file · 0:03")

        let junk = dir.appendingPathComponent("notes.m4a")
        try Data("not audio".utf8).write(to: junk)
        notes.importFile(.success(junk))
        XCTAssertEqual(notes.notice, "That file isn't audio Anu can read.")
        XCTAssertEqual(notes.pending?.seconds, 3, "a bad file leaves the last good one")
    }

    func testRecordedNoteIsKeptEncryptedUntilSentThenOnlyItsWordsRemain() async throws {
        let notes = controller { _ in VoiceNoteTranscription(text: "remind me to call Maya", engine: "Apple", millis: 120) }
        notes.keep(recording(seconds: 17))
        XCTAssertEqual(notes.phase, .ready)
        XCTAssertEqual(notes.pendingTitle, "Voice note · 0:17")
        let file = dir.appendingPathComponent("pending.anuaudio")
        XCTAssertTrue(SecureFile.isEncrypted(file), "pending audio is written only through SecureFile")

        // A new controller (Anu relaunched) finds it again.
        let reopened = controller { _ in VoiceNoteTranscription(text: "x", engine: "Apple", millis: 1) }
        XCTAssertEqual(reopened.pending?.seconds, 17)

        var delivered: VoiceNoteInfo?
        await notes.send(typed: "  for tomorrow ", deliver: { delivered = $0 }, say: { _ in XCTFail("no note expected") })
        let info = try XCTUnwrap(delivered)
        XCTAssertEqual(info.kind, .own)
        XCTAssertEqual(info.seconds, 17)
        XCTAssertEqual(info.transcript, "remind me to call Maya")
        XCTAssertEqual(info.typed, "for tomorrow")
        XCTAssertEqual(info.engine, "Apple")
        XCTAssertEqual(notes.phase, .idle)
        XCTAssertNil(notes.pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the recording is never kept once written down")
    }

    func testSilentNoteEndsWithANoteNotAFailure() async {
        let notes = controller { _ in VoiceNoteTranscription(text: "", engine: "Apple", millis: 1) }
        notes.keep(recording(seconds: 3))
        var said: [String] = []
        await notes.send(typed: "", deliver: { _ in XCTFail("nothing to deliver") }, say: { said.append($0) })
        XCTAssertEqual(said, [VoiceNotePolicy.nothingSaid])
        XCTAssertEqual(notes.phase, .idle)
    }

    func testNoteThatCouldntBeWrittenDownGoesBackToTheComposer() async {
        let notes = controller { _ in throw TranscriptionError.unavailable("On-device speech recognition isn't available for this language.") }
        notes.keep(recording(seconds: 3))
        await notes.send(typed: "", deliver: { _ in XCTFail("nothing to deliver") }, say: { _ in })
        XCTAssertEqual(notes.phase, .ready)
        XCTAssertNotNil(notes.pending)
        XCTAssertTrue(notes.notice?.contains("still here") == true)
    }

    func testRemoveDiscardsThePendingNote() {
        let notes = controller { _ in VoiceNoteTranscription(text: "x", engine: "A", millis: 1) }
        notes.keep(recording(seconds: 2))
        notes.removePending()
        XCTAssertNil(notes.pending)
        XCTAssertEqual(notes.phase, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("pending.anuaudio").path))
    }

    func testInterruptedNoteIsMarkedStoppedEarly() {
        let notes = controller { _ in VoiceNoteTranscription(text: "x", engine: "A", millis: 1) }
        var cut = recording(seconds: 5)
        cut.interrupted = true
        notes.keep(cut)
        XCTAssertEqual(notes.pendingTitle, "Voice note · 0:05 · Stopped early")
    }

    // MARK: Shared recordings

    func testSharedRecordingArrivesSealedAndBecomesASharedNote() throws {
        let drop = SharedVoiceNoteDrop(directory: dir.appendingPathComponent("drop"), keys: keys)
        try drop.drop(SharedVoiceNote(recording: recording(seconds: 4, shared: true)))
        let files = try FileManager.default.contentsOfDirectory(at: drop.directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(SecureFile.isEncrypted(files[0]))

        let notes = controller { _ in VoiceNoteTranscription(text: "x", engine: "A", millis: 1) }
        notes.importShared()
        XCTAssertEqual(notes.pending?.shared, true)
        XCTAssertEqual(notes.pendingTitle, "Shared recording · 0:04")
        XCTAssertTrue(drop.drain().isEmpty, "the hand-off file is removed once read")
    }

    func testTooLongSharedRecordingIsRefusedWithItsLength() throws {
        let drop = SharedVoiceNoteDrop(directory: dir.appendingPathComponent("drop"), keys: keys)
        try drop.drop(SharedVoiceNote(tooLongSeconds: 432))
        let notes = controller { _ in VoiceNoteTranscription(text: "x", engine: "A", millis: 1) }
        notes.importShared()
        XCTAssertNil(notes.pending)
        XCTAssertEqual(notes.notice, "That recording is 7:12 long. Voice notes can be up to 5:00.")
    }

    #if canImport(AVFoundation)
    func testSharedAudioDecoderReadsAWAVFileToMono16k() throws {
        // 1 s of 44.1 kHz audio written as WAV, as another app would share it.
        let rate = 44_100
        let samples = (0..<rate).map { Int16(4_000 * sin(Double($0) * 0.03)) }
        let url = dir.appendingPathComponent("shared.wav")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try WAV.encode(pcm: VoiceRecording.pcmData(samples), sampleRate: rate).write(to: url)
        let note = SharedAudioDecoder.decode(url)
        let recording = try XCTUnwrap(note.recording)
        XCTAssertTrue(recording.shared)
        XCTAssertEqual(recording.sampleRate, 16_000)
        XCTAssertEqual(recording.seconds, 1)
        XCTAssertEqual(SharedAudioDecoder.decode(url, maxSeconds: 0).tooLongSeconds, 1)
        try Data("junk".utf8).write(to: url)
        XCTAssertTrue(SharedAudioDecoder.decode(url).unreadable)
    }
    #endif

    // MARK: Policy: never the cloud

    func testModelTextSaysWhatTheRecordingIs() {
        let own = VoiceNoteInfo(kind: .own, seconds: 17, transcript: "buy milk", typed: "add this")
        XCTAssertEqual(VoiceNotePolicy.modelText(for: own),
                       "add this\n\nMy voice note (0:17), written down on this device: buy milk")
        let shared = VoiceNoteInfo(kind: .shared, seconds: 62, transcript: "meeting moved")
        XCTAssertTrue(VoiceNotePolicy.modelText(for: shared).contains("can hold other people's words"))
        XCTAssertEqual(shared.title, "Shared recording · 1:02")
    }

    func testCloudEscalationIsRefusedWhileAVoiceNoteIsInView() {
        var note = AgentMessage.user("My voice note (0:03): hi")
        note.voiceNote = VoiceNoteInfo(kind: .own, seconds: 3, transcript: "hi")
        let history = [AgentMessage.user("hello"), note]
        XCTAssertNotNil(VoiceNotePolicy.refusal(forTool: "escalate_to_gemini", history: history))
        XCTAssertNotNil(VoiceNotePolicy.refusal(forTool: "escalate_to_private_cloud", history: history))
        XCTAssertNil(VoiceNotePolicy.refusal(forTool: "calculator", history: history))
        XCTAssertNil(VoiceNotePolicy.refusal(forTool: "escalate_to_gemini", history: [.user("hello")]))
    }

    func testVoiceNoteSurvivesSavingAndOlderMessagesStillDecode() throws {
        var message = AgentMessage.user("text")
        message.voiceNote = VoiceNoteInfo(kind: .shared, seconds: 9, transcript: "words", engine: "Apple")
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.voiceNote, message.voiceNote)

        let legacy = try JSONEncoder().encode(AgentMessage.user("old"))
        XCTAssertNil(try JSONDecoder().decode(AgentMessage.self, from: legacy).voiceNote)
    }

    func testVoiceNoteTurnStaysOnDeviceAndRefusesTheCloudBeforeTheLedger() async {
        let sessions = FileManager.default.temporaryDirectory.appendingPathComponent("orch-\(UUID().uuidString)", isDirectory: true)
        let orch = AgentOrchestrator(model: ScriptedModel(), sessionsDirectory: sessions)
        let info = VoiceNoteInfo(kind: .own, seconds: 4, transcript: "hello there")
        await orch.run(voiceNote: info)

        let user = orch.messages.first { $0.role == .user }
        XCTAssertEqual(user?.voiceNote, info)
        XCTAssertTrue(user?.content.contains("hello there") == true)
        XCTAssertNotNil(orch.messages.last { $0.role == .assistant })
        XCTAssertFalse(orch.reasoningSteps.contains { $0.action?.contains("Cloud") == true })

        let ledgerBefore = PrivacyLedger.shared.events.count
        let result = await orch.gatedToolResult(ToolCallInfo(
            name: "escalate_to_gemini", arguments: .object(["task": .string("summarize my note")])))
        XCTAssertTrue(result.contains("never leave this device"))
        XCTAssertEqual(PrivacyLedger.shared.events.count, ledgerBefore, "refused before any ledger entry")
    }
}
