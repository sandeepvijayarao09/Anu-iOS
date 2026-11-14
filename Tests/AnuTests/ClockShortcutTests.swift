import XCTest
@testable import Anu

/// Alarms in the Clock app through the Anu Alarm shortcut.
final class ClockShortcutTests: XCTestCase {
    private let date: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 14; c.hour = 8; c.minute = 5
        return Calendar.current.date(from: c)!
    }()

    func testInputIsTheTimeThenTheLabel() {
        XCTAssertEqual(ClockShortcut.input(label: "Wake\nup", at: date), "2026-11-14 08:05\nWake up")
        XCTAssertEqual(ClockShortcut.input(label: "", at: date), "2026-11-14 08:05\nAlarm")
    }

    func testRunURLNamesTheShortcutAndComesBackToAnu() throws {
        let id = UUID()
        let url = try XCTUnwrap(ClockShortcut.runURL(label: "Gym + run", at: date, id: id))
        XCTAssertTrue(url.absoluteString.hasPrefix("shortcuts://x-callback-url/run-shortcut?"))
        XCTAssertFalse(url.absoluteString.contains("Gym + run"), "values are escaped")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(value("name"), "Anu Alarm")
        XCTAssertEqual(value("input"), "text")
        XCTAssertEqual(value("text"), "2026-11-14 08:05\nGym + run")
        XCTAssertEqual(value("x-success"), "anu://clock-alarm/done?id=\(id.uuidString)")
        XCTAssertEqual(value("x-error"), "anu://clock-alarm/failed?id=\(id.uuidString)")
    }

    func testCallbacksAreRead() throws {
        let id = UUID()
        XCTAssertEqual(ClockShortcut.parse(URL(string: "anu://clock-alarm/done?id=\(id)")!)?.result, .done)
        XCTAssertEqual(ClockShortcut.parse(URL(string: "anu://clock-alarm/cancelled?id=\(id)")!)?.result, .cancelled)
        XCTAssertEqual(ClockShortcut.parse(URL(string: "anu://clock-alarm/failed?id=\(id)&errorMessage=No%20shortcut")!)?.result,
                       .failed("No shortcut"))
        XCTAssertEqual(ClockShortcut.parse(URL(string: "anu://clock-alarm/done?id=\(id)")!)?.id, id)
        XCTAssertNil(ClockShortcut.parse(URL(string: "anu://clock-alarm/done?id=nope")!))
        XCTAssertNil(ClockShortcut.parse(URL(string: "https://clock-alarm/done?id=\(id)")!))
        XCTAssertNil(ClockShortcut.parse(URL(string: "anu://other/done?id=\(id)")!))
    }

    func testAWaitingRunIsResolvedOnce() async {
        let id = UUID()
        let result = await withCheckedContinuation { continuation in
            ClockShortcut.Waiters.shared.add(id, continuation)
            ClockShortcut.Waiters.shared.resolve(id, .done)
            ClockShortcut.Waiters.shared.resolve(id, .noAnswer)   // ignored, no double resume
        }
        XCTAssertEqual(result, .done)
    }

    func testOnlyAlarmsWithinADayGoToClock() {
        let now = date
        XCTAssertTrue(ClockShortcut.fits(now.addingTimeInterval(60), now: now))
        XCTAssertTrue(ClockShortcut.fits(now.addingTimeInterval(23 * 3600), now: now))
        XCTAssertFalse(ClockShortcut.fits(now.addingTimeInterval(25 * 3600), now: now))
        XCTAssertFalse(ClockShortcut.fits(now.addingTimeInterval(-60), now: now))
    }

    func testTheShortcutFileIsSigned() {
        XCTAssertEqual(ClockShortcut.signedFile.prefix(4), Data("AEA1".utf8), "a signed shortcut (Apple Encrypted Archive)")
    }

    func testAnswersSayWhereTheAlarmIs() async throws {
        let args: JSONValue = .object(["action": .string("alarm"), "hour": .int(7), "minute": .int(0)])
        let clock = try await TimerTool(scheduler: Reporting(outcome: .inClock)).execute(arguments: args)
        XCTAssertTrue(clock.hasSuffix("It's in the Clock app."), clock)
        let own = try await TimerTool(scheduler: Reporting(outcome: .ringingNotInClock(why: "Add the shortcut.")))
            .execute(arguments: args)
        XCTAssertTrue(own.contains("won't show in the Clock app. Add the shortcut."), own)
    }
}

private struct Reporting: ReportingTimerScheduling {
    let outcome: ScheduleOutcome
    func schedule(label: String, at date: Date) async -> Bool { true }
    func scheduleReporting(label: String, at date: Date, kind: TimerKind) async -> ScheduleOutcome { outcome }
}

/// What the chat shows when a model throws (seen on the iOS 27 simulator).
@MainActor
final class GenerationErrorTextTests: XCTestCase {
    func testAppleModelCatalogErrorIsExplained() {
        let error = NSError(domain: "com.apple.UnifiedAssetFramework", code: 5000, userInfo: [
            NSLocalizedDescriptionKey: "Generation failed: Model Catalog error: Error Domain=com.apple.UnifiedAssetFramework Code=5000 \"There are no underlying assets\" for asset set com.apple.modelcatalog",
        ])
        let text = AgentOrchestrator.friendlyGenerationError(error)
        XCTAssertTrue(text.hasPrefix("Apple's on-device model isn't ready"), text)
        XCTAssertFalse(text.contains("Domain="))
    }

    func testOtherErrorsLoseTheNSErrorDump() {
        let error = NSError(domain: "x", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Something broke Error Domain=x Code=1 UserInfo={a=b}",
        ])
        XCTAssertEqual(AgentOrchestrator.friendlyGenerationError(error),
                       "The model ran into a problem and couldn't answer (Something broke). Please try again.")
    }

    func testTheFootnoteNamesAppleIntelligence() {
        XCTAssertEqual(EmptyStateView.footnote("Apple on-device"),
                       "Answers on this device with Apple Intelligence · goes to the cloud only when you ask")
        XCTAssertTrue(EmptyStateView.footnote("Gemma 4").contains("with Gemma 4"))
    }
}
