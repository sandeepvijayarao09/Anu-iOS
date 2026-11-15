import Foundation
#if canImport(Speech)
import Speech
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Writes a voice note down, on the device only.
protocol VoiceNoteTranscribing: Sendable {
    /// Shown under the note: "Gemma 4 on this device".
    var engineName: String { get }
    /// The words, possibly empty for a silent recording. Throws
    /// `TranscriptionError.unavailable` when this engine can't run here, so
    /// the chain tries the next one.
    func transcribe(_ recording: VoiceRecording) async throws -> String
}

enum TranscriptionError: Error, Equatable, LocalizedError {
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let why), .failed(let why): return why
        }
    }
}

struct VoiceNoteTranscription: Equatable {
    var text: String
    var engine: String
    var millis: Int
}

/// Tries each engine in order: the first one that can run writes the note
/// down. None of them uses the network.
struct TranscriberChain: Sendable {
    let engines: [any VoiceNoteTranscribing]
    var clock: @Sendable () -> Date = { Date() }

    func transcribe(_ recording: VoiceRecording) async throws -> VoiceNoteTranscription {
        var reasons: [String] = []
        for engine in engines {
            let started = clock()
            do {
                let raw = try await engine.transcribe(recording)
                let millis = Int(clock().timeIntervalSince(started) * 1000)
                return VoiceNoteTranscription(text: VoiceNoteTranscript.clean(raw), engine: engine.engineName, millis: millis)
            } catch TranscriptionError.unavailable(let why) {
                reasons.append(why)
                continue
            }
        }
        throw TranscriptionError.unavailable(
            reasons.last ?? "Voice notes can't be written down on this device.")
    }
}

// MARK: - Gemma 4 audio input (LiteRT-LM)

/// A local model that can hear: Gemma 4 E2B/E4B through LiteRT-LM.
protocol AudioTranscribingModel: Sendable {
    /// Whether this model loaded with its audio encoder.
    func canTranscribeAudio() async -> Bool
    /// The model's words for one WAV piece, with `prompt`.
    func transcribeAudio(wav: Data, prompt: String) async throws -> String
}

/// Gemma 4's own audio input, in a side conversation beside the chat's.
struct GemmaAudioTranscriber: VoiceNoteTranscribing {
    let engineName = "Gemma 4 on this device"
    /// The chat's loaded model, read when a note is sent.
    let model: @Sendable () async -> (any LocalLanguageModel)?

    func transcribe(_ recording: VoiceRecording) async throws -> String {
        guard let hearing = await model() as? AudioTranscribingModel,
              await hearing.canTranscribeAudio() else {
            throw TranscriptionError.unavailable("The loaded model can't hear audio.")
        }
        let samples = recording.samples
        var words: [String] = []
        for range in VoiceNoteTranscript.pieces(samples, sampleRate: recording.sampleRate) {
            let piece = VoiceRecording.pcmData(Array(samples[range]))
            let wav = WAV.encode(pcm: piece, sampleRate: recording.sampleRate)
            let raw = try await hearing.transcribeAudio(wav: wav, prompt: VoiceNoteTranscript.prompt)
            let clean = VoiceNoteTranscript.clean(raw)
            if !clean.isEmpty { words.append(clean) }
        }
        return words.joined(separator: " ")
    }
}

// MARK: - Apple on-device speech

#if canImport(Speech) && canImport(AVFoundation)
/// Apple's speech recognition, on the device only: SpeechAnalyzer's
/// SpeechTranscriber on iOS 26+ when the language model is installed, else
/// SFSpeechRecognizer with `requiresOnDeviceRecognition`. Server recognition
/// is never used: without an on-device recognizer this throws `unavailable`.
/// Audio goes in as buffers from memory; nothing is written to a file.
struct AppleSpeechTranscriber: VoiceNoteTranscribing {
    let engineName = "Apple speech recognition on this device"
    var locale = Locale.current

    func transcribe(_ recording: VoiceRecording) async throws -> String {
        guard let buffer = Self.buffer(for: recording) else {
            throw TranscriptionError.failed("The recording couldn't be read.")
        }
        if #available(iOS 26.0, macOS 26.0, *), let text = try await analyzerTranscript(buffer) {
            return text
        }
        return try await recognizerTranscript(buffer)
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func analyzerTranscript(_ buffer: AVAudioPCMBuffer) async throws -> String? {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        // Only an installed model: fetching one is a download the user starts
        // in Settings, never something a voice note does behind their back.
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier(.bcp47) == supported.identifier(.bcp47) }) else { return nil }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let converted = Self.convert(buffer, to: format) else { return nil }
        let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
        let collector = Task { () throws -> String in
            var text = ""
            for try await result in transcriber.results {
                text += String(result.text.characters)
            }
            return text
        }
        try await analyzer.start(inputSequence: input)
        feed.yield(AnalyzerInput(buffer: converted))
        feed.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    private func recognizerTranscript(_ buffer: AVAudioPCMBuffer) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
              recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.unavailable("On-device speech recognition isn't available for this language.")
        }
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw TranscriptionError.unavailable("Voice notes need Speech Recognition access. Turn it on in Settings › Anu.")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true // never the server
        request.shouldReportPartialResults = false
        request.append(buffer)
        request.endAudio()
        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            let lock = NSLock()
            func finish(_ result: Result<String, Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(with: result)
            }
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    finish(.success(result.bestTranscription.formattedString))
                } else if let error {
                    // "No speech detected" ends a silent note: no words, not a failure.
                    let code = (error as NSError).code
                    if code == 1110 || code == 203 { finish(.success("")) }
                    else { finish(.failure(TranscriptionError.failed(error.localizedDescription))) }
                }
            }
        }
    }

    /// The recording as one float buffer at its own rate.
    static func buffer(for recording: VoiceRecording) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(recording.sampleRate),
                                         channels: 1, interleaved: false) else { return nil }
        let samples = recording.samples
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        for (i, s) in samples.enumerated() { channel[i] = Float(s) / 32_768 }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }
}
#endif

extension TranscriberChain {
    /// The app's chain: Gemma 4's audio input when the loaded model can hear,
    /// else Apple's on-device recognition.
    @MainActor
    static func onDevice() -> TranscriberChain {
        var engines: [any VoiceNoteTranscribing] = [
            GemmaAudioTranscriber(model: { await MainActor.run { AgentOrchestrator.shared.model } }),
        ]
        #if canImport(Speech) && canImport(AVFoundation)
        engines.append(AppleSpeechTranscriber())
        #endif
        return TranscriberChain(engines: engines)
    }
}
