import Foundation

/// The one voice note waiting above the composer, kept through `SecureFile`
/// so leaving Anu, or a note that couldn't be written down, doesn't lose it.
/// Deleted once the note's words are in the thread.
struct PendingVoiceNoteStore {
    let url: URL
    let keys: DataKeyProviding

    init(url: URL = PendingVoiceNoteStore.defaultURL, keys: DataKeyProviding = KeychainDataKey.shared) {
        self.url = url
        self.keys = keys
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("VoiceNotes", isDirectory: true).appendingPathComponent("pending.anuaudio")
    }

    func save(_ recording: VoiceRecording) throws {
        try SecureFile.write(try PropertyListEncoder().encode(recording), to: url, keys: keys)
    }

    func load() -> VoiceRecording? {
        guard let data = SecureFile.read(url, keys: keys) else { return nil }
        return try? PropertyListDecoder().decode(VoiceRecording.self, from: data)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The voice note's lifecycle in the composer (Android ADR-078):
/// record → keep above the composer ("Voice note · 0:17", Remove) → Send
/// writes it down on the device → the turn runs with its words. A note with no
/// words ends with "Nothing was said in this recording."; one that couldn't be
/// written down goes back to the composer so it isn't lost.
@MainActor
final class VoiceNoteController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case ready
        case transcribing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var pending: VoiceRecording?
    @Published var notice: String?

    let recorder: VoiceNoteRecorder
    private let store: PendingVoiceNoteStore
    private let drop: SharedVoiceNoteDrop
    private let transcribe: (VoiceRecording) async throws -> VoiceNoteTranscription

    init(recorder: VoiceNoteRecorder? = nil,
         store: PendingVoiceNoteStore = PendingVoiceNoteStore(),
         drop: SharedVoiceNoteDrop = SharedVoiceNoteDrop(),
         transcribe: ((VoiceRecording) async throws -> VoiceNoteTranscription)? = nil) {
        self.recorder = recorder ?? VoiceNoteRecorder()
        self.store = store
        self.drop = drop
        self.transcribe = transcribe ?? { recording in
            try await TranscriberChain.onDevice().transcribe(recording)
        }
        if let saved = store.load() {
            pending = saved
            phase = .ready
        }
        self.recorder.onFinished = { [weak self] recording in self?.keep(recording) }
        self.recorder.onError = { [weak self] message in
            self?.phase = self?.pending == nil ? .idle : .ready
            self?.notice = message
        }
    }

    var pendingTitle: String? {
        guard let pending else { return nil }
        let kind = pending.shared ? "Shared recording" : "Voice note"
        let early = pending.interrupted ? " · Stopped early" : ""
        return "\(kind) · \(VoiceNoteFormat.duration(pending.seconds))\(early)"
    }

    func startRecording() {
        guard phase == .idle || phase == .ready else { return }
        notice = nil
        removePending()
        phase = .recording
        Task { await recorder.start(); if !recorder.isRecording, phase == .recording { phase = .idle } }
    }

    func stopRecording() { recorder.finish() }
    func cancelRecording() { recorder.cancel(); phase = pending == nil ? .idle : .ready }
    /// The user left Anu: end the recording there, keeping it.
    func appWentToBackground() { if recorder.isRecording { recorder.cutShort() } }

    func removePending() {
        pending = nil
        store.clear()
        if phase == .ready { phase = .idle }
    }

    /// Takes a finished recording into the composer.
    func keep(_ recording: VoiceRecording) {
        guard recording.sampleCount > 0 else { phase = .idle; return }
        pending = recording
        try? store.save(recording)
        phase = .ready
    }

    /// Recordings shared into Anu from other apps.
    func importShared() {
        for item in drop.drain() {
            if let seconds = item.tooLongSeconds {
                notice = "That recording is \(VoiceNoteFormat.duration(seconds)) long. Voice notes can be up to \(VoiceNoteFormat.duration(VoiceRecording.maxSeconds))."
            } else if item.unreadable {
                notice = "That shared file isn't audio Anu can read."
            } else if let recording = item.recording, phase != .recording, phase != .transcribing {
                keep(recording)
            }
        }
    }

    /// Writes the pending note down and hands its words to `send`. Returns
    /// nothing; outcomes land in the thread or back in the composer.
    func send(typed: String, deliver: (VoiceNoteInfo) async -> Void, say: (String) -> Void) async {
        guard let recording = pending, phase == .ready else { return }
        phase = .transcribing
        notice = nil
        do {
            let result = try await transcribe(recording)
            if result.text.isEmpty {
                removePending()
                phase = .idle
                say(VoiceNotePolicy.nothingSaid)
                return
            }
            let typedText = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            let info = VoiceNoteInfo(
                kind: recording.shared ? .shared : .own,
                seconds: recording.seconds,
                transcript: result.text,
                typed: typedText.isEmpty ? nil : typedText,
                interrupted: recording.interrupted,
                engine: result.engine,
                transcribeMillis: result.millis)
            removePending()
            phase = .idle
            await deliver(info)
        } catch {
            phase = .ready
            notice = "Couldn't write the voice note down: \(error.localizedDescription) It's still here, so you can try again."
        }
    }
}
