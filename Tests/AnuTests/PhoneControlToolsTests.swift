import XCTest
@testable import Anu

// MARK: - Fakes (shared with DirectTierTests)

final class PhoneFakeTorch: TorchControlling, @unchecked Sendable {
    var calls: [(on: Bool, level: Double)] = []
    var error: Error?
    func setTorch(on: Bool, level: Double) async throws {
        if let error { throw error }
        calls.append((on, level))
    }
}

final class PhoneFakeScreen: ScreenBrightnessControlling, @unchecked Sendable {
    var levels: [Double] = []
    func setBrightness(_ fraction: Double) async throws { levels.append(fraction) }
}

final class PhoneFakeOpener: URLOpening, @unchecked Sendable {
    var opened: [URL] = []
    var result = true
    func open(_ url: URL) async -> Bool { opened.append(url); return result }
}

final class PhoneFakeSharer: SharePresenting, @unchecked Sendable {
    var shared: [String] = []
    func share(_ text: String) async -> Bool { shared.append(text); return true }
}

final class PhoneFakeScheduler: TimerScheduling, @unchecked Sendable {
    var scheduled: [(label: String, date: Date, kind: TimerKind)] = []
    var result = true
    func schedule(label: String, at date: Date) async -> Bool {
        await schedule(label: label, at: date, kind: .alarm)
    }
    func schedule(label: String, at date: Date, kind: TimerKind) async -> Bool {
        scheduled.append((label, date, kind))
        return result
    }
}

struct PhoneTestError: LocalizedError {
    var errorDescription: String? { "torch busy" }
}

// MARK: - Tools

/// Phone controls (Android parity #16): what each tool does with injected
/// hardware, and the risk tier the broker decides with.
final class PhoneControlToolsTests: XCTestCase {

    // MARK: Flashlight

    func testFlashlightTurnsTheTorchOnAndOff() async throws {
        let torch = PhoneFakeTorch()
        let tool = FlashlightTool(torch: torch)
        let on = try await tool.execute(arguments: .object(["on": .bool(true)]))
        let half = try await tool.execute(arguments: .object(["on": .bool(true), "percent": .int(50)]))
        let off = try await tool.execute(arguments: .object(["on": .bool(false)]))
        XCTAssertEqual([on, half, off], ["Flashlight on.", "Flashlight on.", "Flashlight off."])
        XCTAssertEqual(torch.calls.map(\.on), [true, true, false])
        XCTAssertEqual(torch.calls[0].level, 1.0)
        XCTAssertEqual(torch.calls[1].level, 0.5)
    }

    func testFlashlightFailureThrowsSoTheReceiptSaysFailed() async {
        let torch = PhoneFakeTorch()
        torch.error = PhoneTestError()
        do {
            _ = try await FlashlightTool(torch: torch).execute(arguments: .object(["on": .bool(true)]))
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "torch busy")
        }
    }

    // MARK: Brightness

    func testBrightnessSetsTheScreen() async throws {
        let screen = PhoneFakeScreen()
        let tool = BrightnessTool(screen: screen)
        let out = try await tool.execute(arguments: .object(["percent": .int(40)]))
        XCTAssertEqual(out, "Brightness set to 40%.")
        XCTAssertEqual(screen.levels, [0.4])
        XCTAssertEqual(tool.describe(.object(["percent": .int(40)])), "Set the screen brightness to 40%")
    }

    func testBrightnessOutOfRangeThrows() async {
        let screen = PhoneFakeScreen()
        do {
            _ = try await BrightnessTool(screen: screen).execute(arguments: .object(["percent": .int(150)]))
            XCTFail("expected throw")
        } catch {}
        XCTAssertTrue(screen.levels.isEmpty)
    }

    // MARK: Apps, directions, share

    func testOpenAppByName() async throws {
        let opener = PhoneFakeOpener()
        let tool = OpenNamedAppTool(opener: opener)
        let out = try await tool.execute(arguments: .object(["name": .string("spotify")]))
        XCTAssertEqual(out, "Opened Spotify.")
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["spotify://"])
        XCTAssertEqual(tool.describe(.object(["name": .string("the maps app")])), "Open Maps")
        XCTAssertEqual(tool.sideEffect, .external(capability: .appLaunch))
    }

    func testOpenUnknownOrMissingAppThrows() async {
        let opener = PhoneFakeOpener()
        let tool = OpenNamedAppTool(opener: opener)
        do { _ = try await tool.execute(arguments: .object(["name": .string("Door")])); XCTFail("expected throw") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Spotify"), "names the apps it can open") }
        XCTAssertTrue(opener.opened.isEmpty)

        opener.result = false
        do { _ = try await tool.execute(arguments: .object(["name": .string("Netflix")])); XCTFail("expected throw") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not be installed")) }
    }

    func testPhoneAppsFind() {
        XCTAssertEqual(PhoneApps.find("Google Maps")?.url, "comgooglemaps://")
        XCTAssertEqual(PhoneApps.find("maps")?.name, "Maps")
        XCTAssertEqual(PhoneApps.find("my Notes app")?.name, "Notes")
        XCTAssertNil(PhoneApps.find("the door"))
    }

    func testNavigateBuildsAnAppleMapsLink() async throws {
        XCTAssertEqual(NavigateTool.url(destination: "Golden Gate Park", mode: nil)?.absoluteString,
                       "maps://?daddr=Golden%20Gate%20Park&dirflg=d")
        XCTAssertEqual(NavigateTool.url(destination: "SFO", mode: "walking")?.absoluteString,
                       "maps://?daddr=SFO&dirflg=w")

        let opener = PhoneFakeOpener()
        let tool = NavigateTool(appConfig: AppLauncherConfig(enabled: true, allowedSchemes: ["maps"]), opener: opener)
        let out = try await tool.execute(arguments: .object(["destination": .string("the airport")]))
        XCTAssertEqual(out, "Opened directions to the airport in Maps.")
        XCTAssertEqual(opener.opened.first?.scheme, "maps")
    }

    func testNavigateRespectsTheSchemeAllowlist() async {
        let opener = PhoneFakeOpener()
        let tool = NavigateTool(appConfig: AppLauncherConfig(enabled: true, allowedSchemes: []), opener: opener)
        do { _ = try await tool.execute(arguments: .object(["destination": .string("SFO")])); XCTFail("expected throw") }
        catch {}
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testShareOpensTheSheetWithTheText() async throws {
        let sharer = PhoneFakeSharer()
        let tool = ShareTool(presenter: sharer)
        _ = try await tool.execute(arguments: .object(["text": .string("Meet at 6")]))
        XCTAssertEqual(sharer.shared, ["Meet at 6"])
        XCTAssertEqual(tool.editableFields.map(\.key), ["text"])
    }

    // MARK: Risk tiers

    func testRiskTiers() {
        let none = JSONValue.object([:])
        XCTAssertEqual(FlashlightTool(torch: PhoneFakeTorch()).risk(for: none), .writePrivate)
        XCTAssertEqual(BrightnessTool(screen: PhoneFakeScreen()).risk(for: none), .writePrivate)
        XCTAssertEqual(OpenNamedAppTool(opener: PhoneFakeOpener()).risk(for: none), .writePrivate)
        XCTAssertEqual(NavigateTool(appConfig: .default, opener: PhoneFakeOpener()).risk(for: none), .writePrivate)
        XCTAssertEqual(ShareTool(presenter: PhoneFakeSharer()).risk(for: none), .writeExternal)
        let reminders = RemindersTool()
        XCTAssertEqual(reminders.risk(for: .object(["action": .string("create")])), .writePrivate)
        XCTAssertEqual(reminders.risk(for: .object(["action": .string("list")])), .read)
        XCTAssertEqual(reminders.risk(for: .object(["action": .string("cancel")])), .destructive)
        XCTAssertEqual(reminders.describe(.object(["action": .string("cancel"), "title": .string("call Mom")])),
                       "Delete the reminder “call Mom”")
    }

    // MARK: Timers and alarms

    private var now: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 14, minute: 0))!
    }

    func testAlarmByHourAndMinuteIsTheNextOccurrence() async throws {
        let scheduler = PhoneFakeScheduler()
        let tool = TimerTool(scheduler: scheduler, now: { [now] in now })
        _ = try await tool.execute(arguments: .object(["action": .string("alarm"), "hour": .int(7), "minute": .int(30)]))
        _ = try await tool.execute(arguments: .object(["action": .string("alarm"), "hour": .int(15)]))
        let cal = Calendar.current
        XCTAssertEqual(cal.dateComponents([.day, .hour, .minute], from: scheduler.scheduled[0].date),
                       DateComponents(day: 13, hour: 7, minute: 30), "7:30 has passed today")
        XCTAssertEqual(cal.dateComponents([.day, .hour, .minute], from: scheduler.scheduled[1].date),
                       DateComponents(day: 12, hour: 15, minute: 0))
        XCTAssertEqual(scheduler.scheduled.map(\.kind), [.alarm, .alarm])
        XCTAssertTrue(tool.describe(.object(["action": .string("alarm"), "hour": .int(7), "minute": .int(30)]))
            .contains("7:30"))
    }

    func testTimerSaysItsKindAndFailureThrows() async {
        let scheduler = PhoneFakeScheduler()
        let tool = TimerTool(scheduler: scheduler, now: { [now] in now })
        _ = try? await tool.execute(arguments: .object(["action": .string("timer"), "duration": .string("10 minutes")]))
        XCTAssertEqual(scheduler.scheduled.first?.kind, .timer)

        scheduler.result = false
        do {
            _ = try await tool.execute(arguments: .object(["action": .string("timer"), "duration": .string("1 hour")]))
            XCTFail("a timer that wasn't set must not read as done")
        } catch {}
        XCTAssertNil(TimerTool.nextOccurrence(hour: 24, minute: 0, after: now))
    }

    // MARK: Reminder matching

    func testReminderMatching() {
        let titles = ["Call Mom", "Call the bank", "Buy milk", "Call Mom about Sunday"]
        XCTAssertEqual(ReminderMatching.find("call mom", in: titles), .found(0), "exact wins")
        XCTAssertEqual(ReminderMatching.find("buy", in: titles), .found(2), "the one that starts so")
        XCTAssertEqual(ReminderMatching.find("sunday", in: titles), .found(3), "the one that holds it")
        XCTAssertEqual(ReminderMatching.find("call", in: titles), .ambiguous(["Call Mom", "Call the bank", "Call Mom about Sunday"]))
        XCTAssertEqual(ReminderMatching.find("walk the dog", in: titles), .none)
        XCTAssertEqual(ReminderMatching.find("  ", in: titles), .none)
    }
}

// MARK: - Through the broker

/// The tiers in action: private changes run by themselves on a clean turn and
/// ask once it's tainted; sharing and deleting always ask.
@MainActor
final class PhoneToolPolicyTests: XCTestCase {
    private var asked: [ApprovalRequest] = []

    private func makeBroker() -> ToolBroker {
        let registry = ToolRegistry()
        registry.register(FlashlightTool(torch: PhoneFakeTorch()))
        registry.register(ShareTool(presenter: PhoneFakeSharer()))
        registry.register(RemindersTool())
        let approvals = ApprovalCenter()
        approvals.autoDecide = { [unowned self] request in
            self.asked.append(request)
            return .denied
        }
        return ToolBroker(registry: registry, approvals: approvals, audit: ToolAuditLog(fileURL: nil))
    }

    func testFlashlightRunsByItselfUntilTainted() async {
        let broker = makeBroker()
        let call = ToolCallInfo(name: "phone_flashlight", arguments: .object(["on": .bool(true)]))
        let clean = await broker.handle(call, run: RunState(turnKey: "a"))
        XCTAssertEqual(clean, .ok(result: "Flashlight on.", summary: "Turn the flashlight on", wrote: true))
        XCTAssertTrue(asked.isEmpty)

        let tainted = RunState(turnKey: "b")
        tainted.taint()
        _ = await broker.handle(call, run: tainted)
        XCTAssertEqual(asked.count, 1)
    }

    func testShareAndCancelReminderAlwaysAsk() async {
        let broker = makeBroker()
        let share = await broker.handle(
            ToolCallInfo(name: "phone_share", arguments: .object(["text": .string("hi")])), run: RunState(turnKey: "c"))
        let cancel = await broker.handle(
            ToolCallInfo(name: "reminders", arguments: .object(["action": .string("cancel"), "title": .string("x")])),
            run: RunState(turnKey: "d"))
        XCTAssertEqual(asked.map(\.risk), [.writeExternal, .destructive])
        if case .rejected(_, _, .declined) = share {} else { XCTFail("\(share)") }
        if case .rejected(_, _, .declined) = cancel {} else { XCTFail("\(cancel)") }
    }
}
