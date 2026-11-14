import XCTest
@testable import Anu

/// On device, an alarm "set" by Anu never rang. The answer now says what
/// iOS actually did: a real alarm, a notification only (and why), or nothing.
final class AlarmOutcomeTests: XCTestCase {
    private struct Reporting: ReportingTimerScheduling {
        let outcome: ScheduleOutcome
        func schedule(label: String, at date: Date) async -> Bool { outcome != .failed("") }
        func scheduleReporting(label: String, at date: Date, kind: TimerKind) async -> ScheduleOutcome { outcome }
    }

    private struct Plain: TimerScheduling {
        let ok: Bool
        func schedule(label: String, at date: Date) async -> Bool { ok }
    }

    private let args: JSONValue = .object(["action": .string("alarm"), "hour": .int(8), "minute": .int(0)])

    func testARealAlarmSaysItRings() async throws {
        let text = try await TimerTool(scheduler: Reporting(outcome: .ringing)).execute(arguments: args)
        XCTAssertTrue(text.hasPrefix("Set alarm \"Alarm\" for"), text)
        XCTAssertTrue(text.contains("rings like a Clock alarm"), text)
    }

    func testANotificationSaysItWontRingAndWhy() async throws {
        let why = "Alarms is off for Anu. Turn it on in Settings → Anu → Alarms."
        let text = try await TimerTool(scheduler: Reporting(outcome: .notification(why: why))).execute(arguments: args)
        XCTAssertTrue(text.contains("notification only"), text)
        XCTAssertTrue(text.hasSuffix(why), text)
    }

    func testAFailureThrowsSoTheReceiptSaysFailed() async {
        do {
            _ = try await TimerTool(scheduler: Reporting(outcome: .failed("both off"))).execute(arguments: args)
            XCTFail("a failed alarm must not read as set")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("both off"), error.localizedDescription)
        }
    }

    func testAPlainSchedulerKeepsTheShortAnswer() async throws {
        let text = try await TimerTool(scheduler: Plain(ok: true)).execute(arguments: args)
        XCTAssertTrue(text.hasPrefix("Set alarm"), text)
        XCTAssertFalse(text.contains("notification"), text)
        do {
            _ = try await TimerTool(scheduler: Plain(ok: false)).execute(arguments: args)
            XCTFail("expected a throw")
        } catch {}
    }

    func testWithoutAlarmKitTheSystemSchedulerFallsBackAndSaysSo() async {
        // The simulator test host has no AlarmKit permission prompt to answer;
        // only where AlarmKit is unavailable is the fallback deterministic.
        guard AlarmPermission.current == nil else { return }
        let outcome = await SystemAlarmScheduler(fallback: Plain(ok: true))
            .scheduleReporting(label: "Alarm", at: Date().addingTimeInterval(60), kind: .alarm)
        guard case .notification = outcome else { return XCTFail("\(outcome)") }
    }
}
