import Foundation

/// The user's "Hey Anu" samples (Android ADR-121's WakeVoiceStore): the
/// vectors derived from their voice and the threshold, never audio. Written
/// only through `SecureFile` (AES-GCM with the Keychain's this-device-only key,
/// excluded from backup), so they never leave the phone. Removed by Settings ›
/// Forget my voice and by Delete All My Data.
@MainActor
final class WakeVoiceStore: ObservableObject {
    static let shared = WakeVoiceStore()

    /// Application Support/WakeVoice/voice.bin.
    nonisolated static let folderName = "WakeVoice"

    /// Whether a voice is saved.
    @Published private(set) var hasVoice = false
    /// True while Settings records samples: "Hey Anu" lets go of the
    /// microphone meanwhile.
    @Published var isEnrolling = false
    /// Changes whenever the saved voice does, so the wake path restarts on it.
    @Published private(set) var revision = 0

    let url: URL
    private let keys: DataKeyProviding
    private var cached: WakeVoice?
    private var loaded = false

    init(url: URL? = nil, keys: DataKeyProviding = KeychainDataKey.shared) {
        self.url = url ?? Self.defaultURL
        self.keys = keys
        hasVoice = FileManager.default.fileExists(atPath: self.url.path)
    }

    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent("voice.bin")
    }

    /// Nil when there's none, or it can't be read (another version's
    /// features, or a key that was reset).
    func load() -> WakeVoice? {
        if !loaded {
            cached = SecureFile.read(url, keys: keys).flatMap(WakeVoice.decode)
            loaded = true
        }
        return cached
    }

    func save(_ voice: WakeVoice) throws {
        try SecureFile.write(voice.encode(), to: url, keys: keys)
        cached = voice
        loaded = true
        hasVoice = true
        revision += 1
    }

    func delete() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        cached = nil
        loaded = true
        hasVoice = false
        revision += 1
    }
}

/// The "Teach Anu your voice" sheet's state, apart from the microphone: four
/// samples one at a time, a note after each one that wasn't kept, then save.
@MainActor
final class WakeEnrollmentModel: ObservableObject {
    enum Phase: Equatable {
        case ready
        case recording
        case checking
        case done
    }

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var kept = 0
    @Published private(set) var note: String?
    @Published private(set) var level: Float = 0

    private var session = WakeEnrollmentSession()
    private var take = WakeSampleTake()
    private let features: WakeFeatures
    private let store: WakeVoiceStore

    var total: Int { WakeEnrollment.samples }

    init(store: WakeVoiceStore = .shared, features: WakeFeatures = LogMelFeatures()) {
        self.store = store
        self.features = features
    }

    func began() {
        take = WakeSampleTake()
        note = nil
        level = 0
        phase = .recording
    }

    /// One chunk from the microphone; returns true when the sample can stop.
    func add(_ chunk: [Int16]) -> Bool {
        guard phase == .recording else { return true }
        let done = take.add(chunk)
        level = take.levels.last ?? 0
        return done
    }

    /// The recording stopped: check the sample, drop its audio, save the
    /// voice after the last one.
    func finished() {
        guard phase == .recording else { return }
        phase = .checking
        let audio = take.audio
        take = WakeSampleTake()
        level = 0
        switch session.take(audio, features: features) {
        case .again(let reason):
            note = reason
            phase = .ready
        case .kept(let count):
            kept = count
            note = nil
            if let voice = session.voice() {
                do {
                    try store.save(voice)
                    phase = .done
                } catch {
                    note = "Couldn’t keep your voice on this device. Try again."
                    session = WakeEnrollmentSession()
                    kept = 0
                    phase = .ready
                }
            } else {
                phase = .ready
            }
        }
    }

    /// The microphone wouldn't open, or stopped.
    func failed(_ reason: String) {
        take = WakeSampleTake()
        level = 0
        note = reason.isEmpty ? nil : reason
        phase = .ready
    }
}
