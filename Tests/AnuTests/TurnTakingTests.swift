import XCTest
@testable import Anu

/// Turn-taking (Android ADR-129), ported from TurnTakingTest.kt / VoiceTest.kt.
final class TurnTakingTests: XCTestCase {

    // MARK: Endpointer

    func testFinishedSoundingRequestEndsAfterShortPause() {
        var end = Endpointer()
        end.level(0.05, now: 0)
        end.partial("what's on my", now: 400)
        end.partial("what's on my calendar today", now: 900)
        end.level(0.8, now: 1_000)
        XCTAssertFalse(end.done(now: 1_600))
        XCTAssertTrue(end.done(now: 1_000 + Endpointer.quickMs))
    }

    func testTrailingOffWaitsTheLongPause() {
        var end = Endpointer()
        end.partial("remind me to", now: 500)
        XCTAssertFalse(end.done(now: 500 + Endpointer.quickMs))
        XCTAssertFalse(end.done(now: 500 + Endpointer.slowMs - 1))
        XCTAssertTrue(end.done(now: 500 + Endpointer.slowMs))
        XCTAssertEqual(Endpointer.sounds("set a timer for um"), .unfinished)
        XCTAssertEqual(Endpointer.sounds("text Maya and"), .unfinished)
        XCTAssertEqual(Endpointer.sounds("set"), .unfinished)
    }

    func testOneWordAnswersAreWholeAndNothingEndsBeforeAWord() {
        XCTAssertEqual(Endpointer.sounds("Yes."), .finished)
        XCTAssertEqual(Endpointer.sounds("what should I do"), .finished)
        XCTAssertEqual(Endpointer.sounds("what's the weather like"), .finished)
        var end = Endpointer()
        end.level(0.9, now: 100)
        XCTAssertFalse(end.done(now: 10_000))
        XCTAssertEqual(end.spokeAt, -1)
    }

    func testStillTalkingKeepsTheListenOpen() {
        var end = Endpointer()
        end.level(0.05, now: 0)
        end.partial("call mom", now: 500)
        end.level(0.7, now: 1_100) // loud, no new words: mid-word
        XCTAssertFalse(end.done(now: 1_100 + Endpointer.quickMs))
        XCTAssertTrue(end.done(now: 1_100 + Endpointer.midMs))
    }

    func testUnknownLanguageAlwaysWaitsTheLongPause() {
        XCTAssertEqual(Endpointer.waitFor("¿Qué tengo hoy en el calendario?", language: "es"), Endpointer.slowMs)
        XCTAssertEqual(Endpointer.waitFor("आज मेरे कैलेंडर में क्या है", language: "hi"), Endpointer.slowMs)
        XCTAssertEqual(Endpointer.waitFor("What's on my calendar today", language: "eng"), Endpointer.quickMs)
        var end = Endpointer(language: "de")
        end.partial("Was steht heute in meinem Kalender", now: 0)
        XCTAssertFalse(end.done(now: Endpointer.quickMs))
        XCTAssertTrue(end.done(now: Endpointer.slowMs))
    }

    func testInjectedTimingIsHonoured() {
        var end = Endpointer(quickMs: 100, slowMs: 300)
        end.partial("what's on my calendar today", now: 0)
        XCTAssertTrue(end.done(now: 100))
        end.partial("what's on my calendar today and", now: 200)
        XCTAssertFalse(end.done(now: 400))
        XCTAssertTrue(end.done(now: 500))
    }

    func testCurlyApostrophesAndAccentsAreWords() {
        XCTAssertEqual(Endpointer.sounds("so what\u{2019}s"), .unfinished)
        XCTAssertEqual(Endpointer.sounds("call Zoë back now"), .finished)
    }

    // MARK: Barge-in

    func testTalkingOverAnuFiresItsOwnEchoDoesNot() {
        var detector = BargeInDetector()
        for _ in 0..<15 { XCTAssertFalse(detector.push(0.1)) }
        for k in 0..<35 { XCTAssertFalse(detector.push(k % 3 == 0 ? 0.25 : 0.38)) }
        XCTAssertEqual(detector.threshold ?? 0, 0.48, accuracy: 0.001)
        for _ in 0..<8 { XCTAssertFalse(detector.push(0.6)) }   // a loud word of its own is short
        for _ in 0..<20 { XCTAssertFalse(detector.push(0.3)) }
        var fired = -1
        for k in 0..<30 where detector.push(0.62) && fired < 0 { fired = k }
        XCTAssertEqual(fired, 15)   // 320 ms of the last 400
    }

    func testQuietEchoStillNeedsSomeoneTalkingToThePhone() {
        var detector = BargeInDetector()
        for _ in 0..<50 { _ = detector.push(0.05) }
        XCTAssertEqual(detector.threshold ?? 0, BargeInDetector.minLevel, accuracy: 0.001)
        for _ in 0..<40 { XCTAssertFalse(detector.push(0.4)) }
    }

    func testBeforeCalibrationItNeverFires() {
        var detector = BargeInDetector()
        for _ in 0..<49 { XCTAssertFalse(detector.push(1)) }
        XCTAssertNil(detector.threshold)
    }

    func testChunkLevelsCutTwentyMillisecondChunks() {
        var chunks = ChunkLevels(sampleRate: 16_000)
        XCTAssertEqual(chunks.chunkSize, 320)
        let loud = [Float](repeating: 0.5, count: 700)
        let levels = loud.withUnsafeBufferPointer { chunks.push($0) }
        XCTAssertEqual(levels.count, 2)
        XCTAssertEqual(levels[0], BargeInDetector.level(rms: 0.5), accuracy: 0.0001)
        // The third chunk holds the 60 loud samples left over and 260 silent ones.
        let silence = [Float](repeating: 0, count: 320)
        let mixed = silence.withUnsafeBufferPointer { chunks.push($0) }
        XCTAssertEqual(mixed.count, 1)
        XCTAssertEqual(mixed[0], BargeInDetector.level(rms: (0.25 * 60 / 320).squareRoot()), accuracy: 0.0001)
    }

    func testLevelScale() {
        XCTAssertEqual(BargeInDetector.level(rms: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(BargeInDetector.level(rms: 0.001), 0, accuracy: 0.0001)  // -60 dBFS
        XCTAssertEqual(BargeInDetector.level(rms: 0), 0)
        XCTAssertEqual(BargeInDetector.level(rms: pow(10, -33.0 / 20)), 0.45, accuracy: 0.001)
    }

    // MARK: Spoken sentences

    func testFirstClauseIsSpokenBeforeItsSentenceEnds() {
        let text = "Your next meeting is with Maya at three, and after that you're free"
        let (first, at) = SpokenSentences.next(text, from: 0, final: false, first: true)
        XCTAssertEqual(first, ["Your next meeting is with Maya at three,"])
        XCTAssertEqual(SpokenSentences.next(text, from: at, final: false).sentences, [])
        XCTAssertEqual(SpokenSentences.next("Sure, your next", from: 0, final: false, first: true).sentences, [])
        XCTAssertEqual(SpokenSentences.next("Sure! Your next, one", from: 0, final: false, first: true).sentences, ["Sure!"])
    }

    func testListNumbersAndTitlesDontEndASentence() {
        XCTAssertEqual(SpokenSentences.next("Call Dr. Chen at noon.", from: 0, final: false).sentences, ["Call Dr. Chen at noon."])
        XCTAssertEqual(SpokenSentences.next("1. Milk\n2. Eggs\n", from: 0, final: false).sentences, ["1. Milk", "2. Eggs"])
        XCTAssertEqual(SpokenSentences.next("The answer is no. Okay?", from: 0, final: false).sentences, ["The answer is no.", "Okay?"])
    }

    func testStreamingAnswerIsSpokenSentenceBySentenceWithoutMarkdown() {
        let (first, at) = SpokenSentences.next("Sure! Your **meeting** is at 3", from: 0, final: false)
        XCTAssertEqual(first, ["Sure!"])
        let full = "Sure! Your **meeting** is at 3. Anything else?"
        let (rest, end) = SpokenSentences.next(full, from: at, final: false)
        XCTAssertEqual(rest, ["Your meeting is at 3.", "Anything else?"])
        XCTAssertEqual(SpokenSentences.next(full, from: 0, final: false).next, end)
        XCTAssertEqual(SpokenSentences.next("Here is the [link](https://example.com) to it", from: 0, final: true).sentences,
                       ["Here is the link to it"])
    }

    func testNumbersWithDotsArentSentenceEnds() {
        XCTAssertEqual(SpokenSentences.next("It costs 3.50 today.", from: 0, final: false).sentences, ["It costs 3.50 today."])
    }

    func testOtherScriptsAreSpokenSentenceBySentence() {
        XCTAssertEqual(SpokenSentences.next("今日は晴れです。明日は雨です。午後", from: 0, final: false).sentences, ["今日は晴れです。", "明日は雨です。"])
        XCTAssertEqual(SpokenSentences.next("आज धूप है। कल बारिश होगी। फिर", from: 0, final: false).sentences, ["आज धूप है।", "कल बारिश होगी।"])
        XCTAssertEqual(SpokenSentences.next("هل تريد ذلك؟ ثم", from: 0, final: false).sentences, ["هل تريد ذلك؟"])
        XCTAssertEqual(SpokenSentences.next("你明天上午十点和玛雅开会，然后", from: 0, final: false, first: true).sentences, ["你明天上午十点和玛雅开会，"])
        XCTAssertEqual(SpokenSentences.next("好的，然后", from: 0, final: false, first: true).sentences, [])
    }

    // MARK: Spoken stream

    func testSpokenStreamSpeaksEachPieceOnceInOrder() {
        var stream = SpokenStream()
        var spoken: [String] = []
        let tokens = ["Your next meeting", " is with Maya at three,", " and after", " that you're free.", " Anything", " else?"]
        var text = ""
        for token in tokens {
            text += token
            spoken += stream.feed(text, final: false)
        }
        spoken += stream.feed(text, final: true)
        XCTAssertEqual(spoken, ["Your next meeting is with Maya at three,", "and after that you're free.", "Anything else?"])
        XCTAssertEqual(stream.feed(text, final: true), [])
    }

    func testSpokenStreamNeverReadsToolCallsOrRewrittenText() {
        var stream = SpokenStream()
        XCTAssertEqual(stream.feed("{\"tool\": \"calendar\", \"args\": {}}. ok.", final: false), [])
        XCTAssertEqual(stream.feed("<|tool_call>call:calendar{}", final: true), [])

        var rewritten = SpokenStream()
        XCTAssertEqual(rewritten.feed("Done. I set it", final: false), ["Done."])
        // The settled answer replaced the streamed one: don't re-speak.
        XCTAssertEqual(rewritten.feed("I couldn't set that timer.", final: true), [])
    }

    // MARK: Voice pick

    func testVoicePickPrefersCountryThenQuality() {
        func v(_ id: String, _ lang: String, _ country: String, _ quality: Int) -> TTSVoiceCandidate {
            TTSVoiceCandidate(identifier: id, language: lang, country: country, quality: quality)
        }
        let voices = [v("us-default", "en", "US", 1), v("us-premium", "en", "US", 3),
                      v("gb-premium", "en", "GB", 3), v("de", "de", "DE", 3)]
        XCTAssertEqual(VoicePick.best(voices, language: "en", country: "US")?.identifier, "us-premium")
        XCTAssertEqual(VoicePick.best(voices, language: "en", country: "IN")?.identifier, "gb-premium")
        XCTAssertNil(VoicePick.best(voices, language: "fr", country: "FR"))
    }
}
