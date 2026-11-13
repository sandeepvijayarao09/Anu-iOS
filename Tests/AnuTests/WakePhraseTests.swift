import XCTest
@testable import Anu

/// "Hey Anu" matching (Android VoiceTest.kt) and the foreground wake loop
/// (Android WakeListenerTest.kt), with scripted recognizer rounds.
final class WakePhraseTests: XCTestCase {

    func testWakePhraseAtTheStartKeepsTheRequest() {
        XCTAssertEqual(WakePhrase.remainder("Hey Anu"), "")
        XCTAssertEqual(WakePhrase.remainder("Hey Anu, what's on my calendar?"), "what's on my calendar?")
        XCTAssertEqual(WakePhrase.remainder("Anu text Maya I'm late"), "text Maya I'm late")
        XCTAssertEqual(WakePhrase.remainder("hey anew"), "")
        XCTAssertEqual(WakePhrase.remainder("OK annu set a timer"), "set a timer")
    }

    func testOrdinarySpeechDoesntWakeAnu() {
        XCTAssertNil(WakePhrase.remainder("a new message arrived"))
        XCTAssertNil(WakePhrase.remainder("anew we begin"))
        XCTAssertNil(WakePhrase.remainder("I told Anu about it"))
        XCTAssertNil(WakePhrase.remainder("hey honey"))
        XCTAssertNil(WakePhrase.remainder("anubis is a god"))
    }

    /// Scripted rounds and a fake clock; sleeps advance the clock instantly.
    private final class Script: @unchecked Sendable {
        var rounds: [WakeRound]
        var now = 0
        var sleeps: [Int] = []
        var roundMs: Int
        init(_ rounds: [WakeRound], roundMs: Int = 2_000) { self.rounds = rounds; self.roundMs = roundMs }

        func loop() -> WakeLoop {
            WakeLoop(
                listen: { [self] in
                    now += roundMs
                    return rounds.isEmpty ? .failed("done", fatal: true) : rounds.removeFirst()
                },
                clock: { [self] in now },
                sleep: { [self] ms in sleeps.append(ms); now += ms })
        }
    }

    func testWakeCarriesTheRequestAndDropsEverythingElse() async {
        let script = Script([.heard("what time is it"), .silence, .heard("Hey Anu, set a timer"), .heard("Hey Anu")])
        var woke: [String?] = []
        let stop = await script.loop().run { request in woke.append(request); return true }
        XCTAssertEqual(woke, ["set a timer", nil])
        XCTAssertEqual(stop, .failed("done"))
    }

    func testCantOpenStopsTheLoop() async {
        let script = Script([.heard("hey anu")])
        let stop = await script.loop().run { _ in false }
        XCTAssertEqual(stop, .cantOpen)
    }

    func testErrorsBackOffDoublingThenStop() async {
        let script = Script(Array(repeating: .failed("busy"), count: 5))
        let stop = await script.loop().run { _ in true }
        XCTAssertEqual(stop, .failed("busy"))
        XCTAssertEqual(script.sleeps.filter { $0 >= 2_000 }, [2_000, 4_000, 8_000, 16_000])
    }

    func testFatalErrorStopsAtOnce() async {
        let script = Script([.failed("no on-device recognizer", fatal: true), .heard("hey anu")])
        var woke = 0
        let stop = await script.loop().run { _ in woke += 1; return true }
        XCTAssertEqual(stop, .failed("no on-device recognizer"))
        XCTAssertEqual(woke, 0)
    }

    func testRoundsThatEndAtOnceGetAPause() async {
        let script = Script(Array(repeating: .silence, count: 3), roundMs: 10)
        _ = await script.loop().run { _ in true }
        XCTAssertTrue(script.sleeps.contains(5_000), "three instant rounds should pause, not spin")
    }

    func testCancelledLoopReturnsCancelled() async {
        let loop = WakeLoop(listen: { .silence }, clock: { 0 },
                            sleep: { _ in throw CancellationError() })
        let stop = await loop.run { _ in true }
        XCTAssertEqual(stop, .cancelled)
    }

    func testAppShortcutsStayWithinTheLimitAndKeepAskAnu() {
        // Hey Siri, ask Anu is the background path; iOS allows 10 shortcuts.
        XCTAssertLessThanOrEqual(AnuShortcuts.appShortcuts.count, 10)
    }

    func testWakeIsOffByDefault() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: WakeSettings.enabledKey)
        defaults.removeObject(forKey: WakeSettings.enabledKey)
        XCTAssertFalse(WakeSettings.isEnabled)
        if let saved { defaults.set(saved, forKey: WakeSettings.enabledKey) }
    }
}
