import Foundation
#if os(iOS)
import AVFoundation
#endif

/// Wires turn-taking to the chat (ADR-129): speaks each answer as it streams
/// (the first clause early), runs hands-free live talk in voice mode with
/// barge-in, follows audio-session interruptions and route changes, and runs
/// the foreground "Hey Anu" listener. The decisions live in pure types
/// (`SpokenStream`, `LiveTalk`, `VoiceSessionPolicy`, `WakeLoop`); this class
/// only routes events between them and the audio objects.
@MainActor
final class VoiceLoop: ObservableObject {
    @Published private(set) var liveTalk = LiveTalk()
    @Published private(set) var wakeListening = false
    /// A note for the thread: why live talk or Hey Anu stopped.
    @Published var notice: String?

    // Outputs, set by `attach` (or by tests).
    var enqueueSpeech: (String) -> Void = { _ in }
    var stopSpeech: () -> Void = {}
    var startListening: () -> Void = {}
    var stopListening: () -> Void = {}
    /// Stops listening without sending what was heard (Mute).
    var discardListening: () -> Void = {}
    var cancelAnswer: () -> Void = {}
    var cutRecordingShort: () -> Void = {}
    /// Builds new audio engines after the media server restarted.
    var rebuildAudio: () -> Void = {}
    /// Whether answers should be read aloud right now.
    var shouldSpeak: () -> Bool = { UserDefaults.standard.bool(forKey: SpeechSynthesizer.enabledKey) }
    /// Current state, for the decisions.
    var isThinking: () -> Bool = { false }
    var isSpeaking: () -> Bool = { false }
    var isListening: () -> Bool = { false }
    var isRecordingNote: () -> Bool = { false }
    var awaitingApproval: () -> Bool = { false }
    /// Waits before listening again; injectable so tests don't sleep.
    var after: (Int, @escaping @MainActor () -> Void) -> Void = { ms, work in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            work()
        }
    }

    private var stream = SpokenStream()
    private var streamID: UUID?
    private var turnFloor: Date?
    #if os(iOS)
    private let bargeIn = BargeInMonitor()
    private var wakeRound: WakeRecognizerRound?
    private var observers: [NSObjectProtocol] = []
    #endif
    private var wakeTask: Task<Void, Never>?
    private var wakeFailed = false

    /// Lets Hey Anu try again after it gave up (Anu came back on screen).
    func resetWake() { wakeFailed = false }

    // MARK: Wiring

    func attach(speech: SpeechRecognizer, tts: SpeechSynthesizer) {
        enqueueSpeech = { [weak tts] in tts?.enqueue($0) }
        stopSpeech = { [weak tts] in tts?.stop() }
        startListening = { [weak speech] in
            guard let speech, !speech.isRecording else { return }
            Task { await speech.start() }
        }
        stopListening = { [weak speech] in speech?.stop() }
        discardListening = { [weak speech] in speech?.discard() }
        isSpeaking = { [weak tts] in tts?.isSpeaking ?? false }
        isListening = { [weak speech] in speech?.isRecording ?? false }
        rebuildAudio = { [weak speech, weak tts, weak self] in
            speech?.rebuildAudio()
            tts?.rebuildAudio()
            #if os(iOS)
            self?.bargeIn.rebuild()
            #endif
        }
        speech.onListenEnded = { [weak self] heard, failed in self?.listenEnded(heardWords: heard, failed: failed) }
        tts.onFinished = { [weak self] in self?.speechFinished() }
        #if os(iOS)
        bargeIn.onBargeIn = { [weak self] in self?.bargedIn() }
        observeAudioSession()
        #endif
    }

    // MARK: Speaking answers as they stream

    /// A new turn began: only answers from here on are read aloud.
    func turnStarted(at date: Date = Date()) {
        turnFloor = date
        streamID = nil
        stream = SpokenStream()
    }

    /// Feed the latest message whenever it changes.
    func observe(_ message: AgentMessage?, isThinking: Bool) {
        guard let message, message.role == .assistant,
              let floor = turnFloor, message.timestamp >= floor,
              liveTalk.active || shouldSpeak() else { return }
        if message.id != streamID {
            streamID = message.id
            stream = SpokenStream()
        }
        let final = !message.isStreaming || !isThinking
        for piece in stream.feed(message.content, final: final) {
            enqueueSpeech(piece)
        }
    }

    /// The turn settled: in live talk, listen again unless Anu is speaking.
    func turnEnded() {
        perform(liveTalk.answerDone(isThinking: false, awaitingApproval: awaitingApproval(), isSpeaking: isSpeaking()))
    }

    // MARK: Live talk

    /// Starts live talk; with `listen` false the first turn is already on its
    /// way (a request that came with "Hey Anu").
    func startLiveTalk(listen: Bool = true) {
        notice = nil
        let action = liveTalk.start()
        if listen { perform(action) }
    }

    func stopLiveTalk() {
        liveTalk.stop()
        stopBargeIn()
    }

    /// Mute from the Live Activity: stop listening now and don't listen again
    /// until unmuted; unmuting listens at once.
    func setMuted(_ on: Bool) {
        let action = liveTalk.setMuted(on)
        if on {
            stopBargeIn()
            if isListening() { discardListening() }
        }
        perform(action)
    }

    func listenEnded(heardWords: Bool, failed: Bool) {
        perform(liveTalk.listenEnded(heardWords: heardWords, failed: failed))
    }

    func speechStarted() {
        #if os(iOS)
        if liveTalk.active { bargeIn.start() }
        #endif
    }

    func speechFinished() {
        stopBargeIn()
        perform(liveTalk.answerDone(isThinking: isThinking(), awaitingApproval: awaitingApproval(), isSpeaking: false))
    }

    func bargedIn() {
        perform(liveTalk.bargedIn())
    }

    private func stopBargeIn() {
        #if os(iOS)
        bargeIn.stop()
        #endif
    }

    func perform(_ action: LiveTalk.Action) {
        switch action {
        case .none:
            break
        case .listen(let ms):
            let go: @MainActor () -> Void = { [weak self] in
                guard let self, self.liveTalk.active, !self.liveTalk.muted, !self.isListening(), !self.isSpeaking(),
                      !self.isThinking(), !self.awaitingApproval() else { return }
                self.startListening()
            }
            if ms == 0 { go() } else { after(ms, go) }
        case .interrupt:
            stopBargeIn()
            stopSpeech()
            if isThinking() { cancelAnswer() }
            startListening()
        case .end(let note):
            stopBargeIn()
            notice = note
        }
    }

    // MARK: Audio session

    func handle(_ event: VoiceSessionPolicy.Event) {
        let state = VoiceSessionPolicy.State(liveTalk: liveTalk.active, listening: isListening(),
                                             speaking: isSpeaking(), recordingNote: isRecordingNote())
        for effect in VoiceSessionPolicy.effects(of: event, state: state) {
            switch effect {
            case .stopListening: stopListening()
            case .stopSpeaking: stopSpeech(); stopBargeIn()
            case .cutRecordingShort: cutRecordingShort()
            case .reactivateSession:
                #if os(iOS)
                try? AVAudioSession.sharedInstance().setActive(true, options: [])
                #endif
            case .resumeListening: perform(.listen(afterMs: LiveTalk.relistenDelayMs))
            case .rebuildAudio:
                stopBargeIn()
                rebuildAudio()
            }
        }
    }

    #if os(iOS)
    private func observeAudioSession() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            Task { @MainActor [weak self] in
                switch type {
                case .began: self?.handle(.interruptionBegan)
                case .ended: self?.handle(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
                default: break
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            Task { @MainActor [weak self] in
                switch reason {
                case .oldDeviceUnavailable: self?.handle(.oldDeviceUnavailable)
                case .newDeviceAvailable: self?.handle(.newDeviceAvailable)
                default: break
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handle(.mediaServicesReset) }
        })
    }
    #endif

    // MARK: Hey Anu (foreground only)

    /// Runs the wake listener only while `eligible`: the switch is on, Anu is
    /// open and on screen, and nothing else is using the microphone.
    func updateWake(eligible: Bool, onWake: @escaping @MainActor (String?) -> Void) {
        #if os(iOS)
        if eligible, wakeTask == nil, !wakeFailed {
            let round = WakeRecognizerRound()
            wakeRound = round
            wakeListening = true
            let loop = WakeLoop(
                listen: { await round.listen() },
                clock: VoiceClock.nowMs,
                sleep: { ms in try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) })
            wakeTask = Task { @MainActor [weak self] in
                let stop = await loop.run { request in
                    self?.stopWake()
                    onWake(request)
                    return true
                }
                if case .failed(let why) = stop { self?.notice = why; self?.wakeFailed = true }
                if self?.wakeRound === round { self?.wakeTask = nil; self?.wakeListening = false }
            }
        } else if !eligible {
            stopWake()
        }
        #endif
    }

    func stopWake() {
        wakeTask?.cancel()
        wakeTask = nil
        wakeListening = false
        #if os(iOS)
        wakeRound?.cancel()
        wakeRound = nil
        #endif
    }
}
