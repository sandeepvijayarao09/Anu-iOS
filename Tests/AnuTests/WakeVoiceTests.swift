import CryptoKit
import XCTest
@testable import Anu

/// "Hey Anu" from the user's samples (Android ADR-121, WakeVoiceTest.kt and
/// WakeDetectorTest.kt), on log-mel features and generated audio: tones for
/// the features and the speech span, `SyntheticSpeech` voices end to end.
final class WakeVoiceTests: XCTestCase {
    typealias Speech = SyntheticSpeech

    // MARK: Audio helpers

    private func tone(_ hz: Double, ms: Double, dbfs: Double = -20, rate: Double = 16_000) -> [Int16] {
        let count = Int(ms / 1_000 * rate)
        let amplitude = pow(10, dbfs / 20) * 32_768 * 2.squareRoot()
        return (0..<count).map { Int16((amplitude * sin(2 * .pi * hz * Double($0) / rate)).rounded()) }
    }

    private func silence(ms: Double) -> [Int16] { Array(repeating: 0, count: Int(ms * 16)) }

    private func noise(ms: Double, dbfs: Double, seed: UInt64 = 7) -> [Int16] {
        var random = Speech.Random(seed: seed)
        let sigma = pow(10, dbfs / 20) * 32_768
        return (0..<Int(ms * 16)).map { _ in Int16(max(-32_768, min(32_767, (sigma * random.gaussian()).rounded()))) }
    }

    private func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        1 - zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private func norm(_ v: [Float]) -> Float { v.reduce(0) { $0 + $1 * $1 }.squareRoot() }

    // MARK: Features

    func testFeaturesAreUnitLengthAndRepeatable() {
        let audio = noise(ms: 400, dbfs: -60) + tone(300, ms: 400) + tone(1_200, ms: 400)
        let first = LogMelFeatures().vectors(of: audio)
        let again = LogMelFeatures().vectors(of: audio)
        XCTAssertEqual(first.count, audio.count / WakeAudio.chunk)
        XCTAssertEqual(first, again)
        // A stream's first vector is its own mean, so it has no direction yet.
        XCTAssertEqual(norm(first[0]), 0)
        for vector in first.dropFirst() {
            XCTAssertEqual(vector.count, LogMelFeatures.bands)
            XCTAssertEqual(norm(vector), 1, accuracy: 1e-4)
        }
        // A reused stream that was reset gives the same vectors.
        let features = LogMelFeatures()
        _ = features.vectors(of: tone(800, ms: 1_000))
        XCTAssertEqual(features.vectors(of: audio), first)
    }

    func testDigitalSilenceHasNoDirection() {
        let vectors = LogMelFeatures().vectors(of: silence(ms: 400))
        XCTAssertTrue(vectors.allSatisfy { norm($0) == 0 })
    }

    func testMeanNormalisationIgnoresLoudness() {
        let quiet = noise(ms: 300, dbfs: -70) + tone(400, ms: 300, dbfs: -36) + tone(1_500, ms: 300, dbfs: -36)
        let loud = quiet.map { Int16(clamping: Int($0) * 8) }  // +18 dB
        let a = LogMelFeatures().vectors(of: quiet)
        let b = LogMelFeatures().vectors(of: loud)
        for (x, y) in zip(a, b).dropFirst(2) { XCTAssertLessThan(cosineDistance(x, y), 0.01) }
    }

    func testDifferentSoundsAreFarApart() {
        let features = LogMelFeatures()
        let low = features.vectors(of: noise(ms: 800, dbfs: -60) + tone(250, ms: 400))
        let high = features.vectors(of: noise(ms: 800, dbfs: -60) + tone(2_500, ms: 400))
        XCTAssertGreaterThan(cosineDistance(low.last!, high.last!), 0.5)
    }

    func testMelFiltersCoverTheBandInOrder() {
        let filters = LogMelFeatures.melFilters(bands: 32, bins: 257, rate: 16_000, low: 60, high: 7_600)
        var peaks: [Int] = []
        for band in 0..<32 {
            let row = Array(filters[(band * 257)..<((band + 1) * 257)])
            XCTAssertGreaterThan(row.max()!, 0, "band \(band) is empty")
            peaks.append(row.firstIndex(of: row.max()!)!)
        }
        XCTAssertEqual(peaks, peaks.sorted())
        XCTAssertLessThan(peaks.first!, 5)
        XCTAssertGreaterThan(peaks.last!, 220)
    }

    // MARK: Distance and matcher

    private func frames(_ seed: Int, count: Int) -> [[Float]] {
        var random = Speech.Random(seed: UInt64(seed))
        return (0..<count).map { _ in WakeVector.unit((0..<8).map { _ in Float(random.gaussian()) }) }
    }

    func testDistanceIsZeroForTheSameSoundAnywhereBeforeTheEnd() {
        let template = frames(1, count: 6)
        XCTAssertEqual(WakeDistance.of(template, template), 0, accuracy: 1e-5)
        // An open start: anything may come first.
        XCTAssertEqual(WakeDistance.of(template, frames(2, count: 5) + template), 0, accuracy: 1e-5)
        // Said slower: each frame twice.
        XCTAssertEqual(WakeDistance.of(template, template.flatMap { [$0, $0] }), 0, accuracy: 1e-5)
        // But it must end at the last frame.
        XCTAssertGreaterThan(WakeDistance.of(template, template + frames(3, count: 3)), 0.2)
        XCTAssertEqual(WakeDistance.of([], template), .greatestFiniteMagnitude)
        XCTAssertEqual(WakeDistance.of(template, [[Float]]()), .greatestFiniteMagnitude)
    }

    func testMatcherFindsASampleAtTheEndOfLiveAudio() {
        let a = WakeTemplate(frames: frames(1, count: 6))
        let b = WakeTemplate(frames: frames(4, count: 8))
        var matcher = WakeMatcher(voice: WakeVoice(templates: [a, b], threshold: 0.1))
        var distances: [Float] = []
        for frame in frames(5, count: 30) + b.frames + frames(6, count: 4) { distances.append(matcher.push(frame)) }
        XCTAssertEqual(distances[30 + 7], 0, accuracy: 1e-5)
        XCTAssertGreaterThan(distances[10], 0.2)
        XCTAssertGreaterThan(distances.last!, 0.2)
        // Too little audio for any sample yet.
        matcher.reset()
        XCTAssertEqual(matcher.push(frames(7, count: 1)[0]), .greatestFiniteMagnitude)
    }

    func testTriggerFiresAtTheClosestPoint() {
        var trigger = WakeTrigger(threshold: 0.1)
        XCTAssertNil(trigger.push(0.3))
        XCTAssertNil(trigger.push(0.08))
        XCTAssertNil(trigger.push(0.05))
        XCTAssertEqual(trigger.push(0.06), .woke(0.05))
        // At most three chunks after it first dipped.
        XCTAssertNil(trigger.push(0.09))
        XCTAssertNil(trigger.push(0.08))
        XCTAssertNil(trigger.push(0.07))
        XCTAssertEqual(trigger.push(0.06), .woke(0.06))
        // Near misses are reported once the distance goes back up.
        XCTAssertNil(trigger.push(0.12))
        XCTAssertNil(trigger.push(0.11))
        XCTAssertEqual(trigger.push(0.4), .nearMiss(0.11))
        XCTAssertNil(trigger.push(0.4))
    }

    // MARK: Storage

    func testVoiceRoundTripsAndRejectsOtherBytes() {
        let voice = WakeVoice(templates: [WakeTemplate(frames: frames(1, count: 3)), WakeTemplate(frames: frames(2, count: 5))],
                              threshold: 0.0625)
        let bytes = voice.encode()
        XCTAssertEqual(WakeVoice.decode(bytes), voice)
        XCTAssertEqual(Array(bytes.prefix(4)), [0, 0, 0, 2], "big-endian version, as Android writes it")
        XCTAssertNil(WakeVoice.decode(bytes.dropLast(1)))
        XCTAssertNil(WakeVoice.decode(bytes + Data([0])))
        var android = bytes
        android[3] = 1  // Android's version holds openWakeWord embeddings.
        XCTAssertNil(WakeVoice.decode(android))
        XCTAssertNil(WakeVoice.decode(Data()))
    }

    @MainActor
    func testStoreKeepsTheVoiceEncryptedAndForgetsIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wake-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(WakeVoiceStore.folderName).appendingPathComponent("voice.bin")
        let keys = StaticDataKey(key: SymmetricKey(size: .bits256))
        let store = WakeVoiceStore(url: url, keys: keys)
        XCTAssertFalse(store.hasVoice)
        XCTAssertNil(store.load())
        let voice = WakeVoice(templates: [WakeTemplate(frames: frames(1, count: 4))], threshold: 0.07)
        try store.save(voice)
        XCTAssertTrue(store.hasVoice)
        XCTAssertTrue(SecureFile.isEncrypted(url))
        XCTAssertEqual(WakeVoiceStore(url: url, keys: keys).load(), voice)
        // Another key (a reset Keychain) reads nothing rather than garbage.
        XCTAssertNil(WakeVoiceStore(url: url, keys: StaticDataKey(key: SymmetricKey(size: .bits256))).load())
        let revision = store.revision
        store.delete()
        XCTAssertFalse(store.hasVoice)
        XCTAssertNil(store.load())
        XCTAssertGreaterThan(store.revision, revision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    func testDeleteAllMyDataRemovesTheSamples() {
        XCTAssertTrue(DataEraser.knownApplicationSupport.contains(WakeVoiceStore.folderName))
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("erase-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let file = support.appendingPathComponent(WakeVoiceStore.folderName).appendingPathComponent("voice.bin")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data([1]))
        let eraser = DataEraser(locations: [.init(directory: support, only: DataEraser.knownApplicationSupport)],
                                defaultsDomain: nil, keychainServices: [],
                                markerURL: support.appendingPathComponent(".marker"))
        eraser.eraseStoredData()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Enrollment checks

    func testSpeechSpanSkipsTheRoomAndKeepsAShortPause() {
        let audio = noise(ms: 500, dbfs: -60) + tone(300, ms: 250) + silence(ms: 150) + tone(600, ms: 300) + noise(ms: 600, dbfs: -60)
        let span = WakeEnrollment.speech(audio)!
        XCTAssertEqual(Double(span.lowerBound), 500 * 16, accuracy: 160)
        XCTAssertEqual(Double(span.upperBound), 1_200 * 16, accuracy: 160)
    }

    func testSpeechSpanLeavesOutOtherSoundAfterALongPause() {
        let audio = silence(ms: 300) + tone(300, ms: 400, dbfs: -14) + silence(ms: 400) + tone(600, ms: 300, dbfs: -30) + silence(ms: 300)
        let span = WakeEnrollment.speech(audio)!
        XCTAssertEqual(Double(span.upperBound), 700 * 16, accuracy: 160)
    }

    func testSpeechSpanNeedsSomethingLoudEnough() {
        XCTAssertNil(WakeEnrollment.speech(silence(ms: 1_000)))
        XCTAssertNil(WakeEnrollment.speech(noise(ms: 1_000, dbfs: -30)))  // steady noise, no speech above it
        XCTAssertNil(WakeEnrollment.speech(silence(ms: 300) + tone(300, ms: 400, dbfs: -45) + silence(ms: 300)))
        XCTAssertNil(WakeEnrollment.speech([1, 2, 3]))
    }

    func testSamplesAskAgainWithAndroidsWords() {
        let features = LogMelFeatures()
        func check(_ audio: [Int16]) -> WakeEnrollment.Sample {
            WakeEnrollment.sample(audio, vectors: features.vectors(of: audio))
        }
        XCTAssertEqual(check(silence(ms: 2_000)), .again("Didn’t hear you. Say “Hey Anu” a little louder."))
        XCTAssertEqual(check(silence(ms: 500) + tone(500, ms: 150) + silence(ms: 800)),
                       .again("That was very short. Say “Hey Anu” again."))
        XCTAssertEqual(check(silence(ms: 300) + tone(500, ms: 2_500) + silence(ms: 500)),
                       .again("There’s other sound around you. Say just “Hey Anu”, close to the phone."))
        guard case .learned(let template) = check(silence(ms: 500) + tone(500, ms: 400) + tone(900, ms: 400) + silence(ms: 600)) else {
            return XCTFail("a clear sample is learned")
        }
        // The chunks at least half inside the 800 ms of sound.
        XCTAssertEqual(template.frames.count, 10)
    }

    func testRecordingEndsAfterSpeechThenQuiet() {
        let quiet: [Float] = Array(repeating: 0.1, count: 6)
        let speech: [Float] = Array(repeating: 0.6, count: 8)
        XCTAssertFalse(WakeEnrollment.ended([]))
        XCTAssertFalse(WakeEnrollment.ended(quiet + quiet + quiet))
        XCTAssertFalse(WakeEnrollment.ended(quiet + speech + Array(repeating: 0.1, count: 7)))
        XCTAssertTrue(WakeEnrollment.ended(quiet + speech + Array(repeating: 0.1, count: 8)))
        // A noisy room ends too, measured from its own floor.
        XCTAssertTrue(WakeEnrollment.ended(Array(repeating: 0.5, count: 4) + Array(repeating: 0.8, count: 6)
                                           + Array(repeating: 0.55, count: 8)))
        // Too quiet to be speech never counts as speech.
        XCTAssertFalse(WakeEnrollment.ended([0] + Array(repeating: 0.3, count: 5) + Array(repeating: 0, count: 10)))
    }

    func testLevelIsDecibelsFromMinusSixtyToFullScale() {
        XCTAssertEqual(WakeEnrollment.level([]), 0)
        XCTAssertEqual(WakeEnrollment.level(silence(ms: 80)), 0)
        XCTAssertEqual(WakeEnrollment.level(Array(repeating: 32_767, count: 1_280)), 1, accuracy: 1e-3)
        XCTAssertEqual(WakeEnrollment.level(tone(440, ms: 80, dbfs: -30)), 0.5, accuracy: 0.01)
    }

    func testSampleTakeStopsWhenTheUserStopsOrAtFourSeconds() {
        var take = WakeSampleTake()
        let chunks = noise(ms: 400, dbfs: -60) + tone(400, ms: 640) + noise(ms: 2_000, dbfs: -60)
        var stoppedAt: Int?
        for k in 0..<(chunks.count / WakeAudio.chunk) where stoppedAt == nil {
            if take.add(Array(chunks[(k * WakeAudio.chunk)..<((k + 1) * WakeAudio.chunk)])) { stoppedAt = k }
        }
        XCTAssertEqual(stoppedAt, 5 + 8 + 8 - 1)
        var endless = WakeSampleTake()
        let loud = tone(400, ms: 80)
        for k in 0..<WakeSampleTake.maxChunks { XCTAssertEqual(endless.add(loud), k == WakeSampleTake.maxChunks - 1) }
    }

    func testThresholdIsTheSamplesSpreadTimesTheMarginClamped() {
        let a = WakeTemplate(frames: frames(1, count: 6))
        let same = WakeEnrollment.voice([a, a, a, a])
        XCTAssertEqual(same.threshold, WakeEnrollment.minThreshold)
        let spread = WakeEnrollment.voice([a, WakeTemplate(frames: frames(2, count: 6))])
        XCTAssertEqual(spread.threshold, WakeEnrollment.maxThreshold)
        XCTAssertTrue(WakeEnrollment.fits(a, kept: []))
        XCTAssertTrue(WakeEnrollment.fits(a, kept: [a]))
        XCTAssertFalse(WakeEnrollment.fits(a, kept: [WakeTemplate(frames: frames(2, count: 6))]))
    }

    // MARK: End to end on synthetic voices

    /// Four takes of "Hey Anu" from one voice, each a little different.
    private func enroll(pitch: Double = 120, tract: Double = 1) -> (WakeVoice, [WakeEnrollmentSession.Outcome]) {
        var session = WakeEnrollmentSession()
        let features = LogMelFeatures()
        let speeds = [0.9, 1.0, 1.1, 0.95], leads = [300.0, 600, 900, 450]
        var outcomes: [WakeEnrollmentSession.Outcome] = []
        for k in 0..<4 {
            let voice = Speech.Voice(pitch: pitch * (k % 2 == 0 ? 1.04 : 0.96), tract: tract * (1 + 0.015 * Double(k - 1)),
                                     speed: speeds[k], level: -18 - Double(k) * 2, noise: -55, seed: UInt64(k))
            outcomes.append(session.take(Speech.say(Speech.heyAnu, voice: voice, leadMs: leads[k]), features: features))
        }
        return (session.voice()!, outcomes)
    }

    /// The closest the stream came, and whether the detector woke.
    private func listen(_ voice: WakeVoice, to phrase: [Speech.Segment], as speaker: Speech.Voice) -> (Float, Bool) {
        let audio = Speech.say(phrase, voice: speaker, leadMs: 1_500, trailMs: 600)
        let detector = WakeVoiceMatcher(voice: voice)
        var matcher = WakeMatcher(voice: voice)
        let features = LogMelFeatures()
        var best = Float.greatestFiniteMagnitude
        var woke = false
        for k in 0..<(audio.count / WakeAudio.chunk) {
            let chunk = Array(audio[(k * WakeAudio.chunk)..<((k + 1) * WakeAudio.chunk)])
            best = min(best, matcher.push(features.push(chunk)))
            woke = detector.push(chunk) || woke
        }
        return (best, woke)
    }

    func testFourTakesMakeAVoiceThatWakesOnlyForHeyAnu() {
        let (voice, outcomes) = enroll()
        XCTAssertEqual(outcomes, [.kept(1), .kept(2), .kept(3), .kept(4)])
        XCTAssertEqual(voice.templates.count, 4)
        XCTAssertGreaterThanOrEqual(voice.threshold, WakeEnrollment.minThreshold)
        XCTAssertLessThanOrEqual(voice.threshold, WakeEnrollment.maxThreshold)

        for (speed, seed) in [(1.05, 500), (0.92, 501), (1.12, 502)] {
            let (distance, woke) = listen(voice, to: Speech.heyAnu,
                                          as: Speech.Voice(pitch: 120, speed: speed, level: -22, noise: -50, seed: UInt64(seed)))
            XCTAssertTrue(woke, "Hey Anu at \(speed)× came to \(distance), threshold \(voice.threshold)")
        }
        for (name, phrase) in [("Hey Andrew", Speech.heyAndrew), ("Hey Siri", Speech.heySiri),
                               ("a new message", Speech.aNewMessage), ("Good morning", Speech.goodMorning)] {
            let (distance, woke) = listen(voice, to: phrase, as: Speech.Voice(pitch: 120, level: -20, noise: -50, seed: 700))
            XCTAssertFalse(woke, "\(name) came to \(distance), threshold \(voice.threshold)")
        }
    }

    func testAnotherPhraseIsAskedForAgain() {
        var session = WakeEnrollmentSession()
        let features = LogMelFeatures()
        XCTAssertEqual(session.take(Speech.say(Speech.heyAnu, voice: Speech.Voice(seed: 1)), features: features), .kept(1))
        XCTAssertEqual(session.take(Speech.say(Speech.goodMorning, voice: Speech.Voice(seed: 2)), features: features),
                       .again("That sounded different from the others. Say “Hey Anu” as you did before."))
        XCTAssertEqual(session.kept.count, 1)
        XCTAssertNil(session.voice())
    }

    @MainActor
    func testEnrollmentSheetModelSavesAfterFourGoodSamples() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("enroll-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WakeVoiceStore(url: folder.appendingPathComponent("voice.bin"),
                                   keys: StaticDataKey(key: SymmetricKey(size: .bits256)))
        let model = WakeEnrollmentModel(store: store)
        func record(_ audio: [Int16]) {
            model.began()
            XCTAssertEqual(model.phase, .recording)
            var stopped = false
            for k in 0..<(audio.count / WakeAudio.chunk) where !stopped {
                stopped = model.add(Array(audio[(k * WakeAudio.chunk)..<((k + 1) * WakeAudio.chunk)]))
            }
            model.finished()
        }
        record(silence(ms: 2_000))
        XCTAssertEqual(model.note, WakeEnrollment.quietMessage)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.kept, 0)
        for k in 0..<4 {
            record(Speech.say(Speech.heyAnu, voice: Speech.Voice(speed: 1 + 0.05 * Double(k - 1), seed: UInt64(k))))
            XCTAssertNil(model.note)
            XCTAssertEqual(model.kept, k + 1)
        }
        XCTAssertEqual(model.phase, .done)
        XCTAssertTrue(store.hasVoice)
        XCTAssertEqual(store.load()?.templates.count, 4)
    }

    // MARK: The loop and the chunker

    func testChunkerCutsEightyMillisecondChunks() {
        var chunker = WakeChunker()
        XCTAssertTrue(chunker.add(Array(repeating: 1, count: 1_000)).isEmpty)
        let chunks = chunker.add(Array(repeating: 2, count: 2_000))
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, WakeAudio.chunk)
        XCTAssertEqual(chunks[0].prefix(1_000), ArraySlice(Array(repeating: Int16(1), count: 1_000)))
        XCTAssertEqual(chunker.add(Array(repeating: 3, count: 839)).count, 0)
        XCTAssertEqual(chunker.add([4]).count, 1)
    }

    private final class Rounds: @unchecked Sendable {
        var rounds: [WakeVoiceRound]
        var sleeps: [Int] = []
        init(_ rounds: [WakeVoiceRound]) { self.rounds = rounds }

        func loop() -> WakeVoiceLoop {
            WakeVoiceLoop(listen: { [self] in rounds.isEmpty ? .cancelled : rounds.removeFirst() },
                          sleep: { [self] ms in sleeps.append(ms) })
        }
    }

    func testLoopWakesWithNoRequestAndRetriesTheMicrophone() async {
        let rounds = Rounds([.woke, .micFailed("busy"), .micFailed("busy"), .woke, .woke])
        var wakes = 0
        let stop = await rounds.loop().run { wakes += 1; return true }
        XCTAssertEqual(wakes, 3)
        XCTAssertEqual(rounds.sleeps, [2_000, 4_000])
        XCTAssertEqual(stop, .cancelled)
    }

    func testLoopStopsAfterFiveFailuresOrWhenAnuCantOpen() async {
        let failing = Rounds(Array(repeating: .micFailed("The microphone is in use."), count: 6))
        let stop = await failing.loop().run { true }
        XCTAssertEqual(stop, .failed("The microphone is in use."))
        XCTAssertEqual(failing.sleeps, [2_000, 4_000, 8_000, 16_000])
        let cantOpen = await Rounds([.woke]).loop().run { false }
        XCTAssertEqual(cantOpen, .cantOpen)
    }
}
