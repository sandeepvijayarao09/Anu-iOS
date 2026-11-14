import XCTest
@testable import Anu

/// The Direct tier's parser (Android parity #17, ADR-076): whole phone commands
/// become one tool call; near misses fall through to the model (nil).
final class PhoneCommandsTests: XCTestCase {
    /// Thursday 12 November 2026, 14:00 in Los Angeles.
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 14, minute: 0))!
    }

    private func match(_ text: String) -> DirectCommand? {
        PhoneCommands.match(text, now: now, calendar: calendar)
    }

    private func tool(_ name: String, _ args: [String: JSONValue]) -> DirectCommand {
        .tool(name: name, arguments: .object(args))
    }

    // MARK: Timers and alarms

    func testTimers() {
        let timer = { (d: String) in self.tool("set_timer", ["action": .string("timer"), "duration": .string(d)]) }
        XCTAssertEqual(match("set a timer for 10 minutes"), timer("10 minutes"))
        XCTAssertEqual(match("Start a 5-minute timer."), timer("5 minutes"))
        XCTAssertEqual(match("set a timer for an hour"), timer("1 hour"))
        XCTAssertEqual(match("timer for ninety seconds"), timer("90 seconds"))
        XCTAssertEqual(match("Please set a timer for twenty minutes"), timer("20 minutes"))
    }

    func testTimerNearMissesFallThrough() {
        XCTAssertNil(match("set a timer for 10 minutes and email Maya the agenda"))
        XCTAssertNil(match("set a timer"))
        XCTAssertNil(match("set a timer for 25 hours"), "longer than a day")
        XCTAssertNil(match("how long is a 10 minute timer"))
    }

    func testAlarms() {
        let alarm = { (h: Int, m: Int) in
            self.tool("set_timer", ["action": .string("alarm"), "hour": .int(h), "minute": .int(m)])
        }
        XCTAssertEqual(match("alarm at 7am"), alarm(7, 0))
        XCTAssertEqual(match("Set an alarm for 6:45 pm"), alarm(18, 45))
        XCTAssertEqual(match("wake me up at 12 am"), alarm(0, 0))
        XCTAssertEqual(match("set alarm for 12 p.m."), alarm(12, 0))
        XCTAssertEqual(match("alarm for 21:30"), alarm(21, 30))
    }

    /// "Set an alarm for 8 am tomorrow" went to the model on device, which
    /// said it was set without setting it. A day is the Direct tier's now.
    func testAlarmsWithADay() {
        let at = { (time: String) in self.tool("set_timer", ["action": .string("alarm"), "time": .string(time)]) }
        XCTAssertEqual(match("Set an alarm for 8 am tomorrow"), at("2026-11-13 08:00"))
        XCTAssertEqual(match("set an alarm for tomorrow at 6:30am"), at("2026-11-13 06:30"))
        XCTAssertEqual(match("wake me up tomorrow at 7"), at("2026-11-13 07:00"))
        XCTAssertEqual(match("wake me up at 7 tomorrow morning"), at("2026-11-13 07:00"))
        XCTAssertEqual(match("set an alarm for 9 tonight"), at("2026-11-12 21:00"))
        XCTAssertEqual(match("alarm for 5 pm today"), at("2026-11-12 17:00"))
        XCTAssertEqual(match("set an alarm for 7 in the morning"),
                       tool("set_timer", ["action": .string("alarm"), "hour": .int(7), "minute": .int(0)]))
    }

    func testAlarmNearMissesFallThrough() {
        XCTAssertNil(match("alarm at 13 pm"))
        XCTAssertNil(match("set an alarm for 7:75"))
        XCTAssertNil(match("set an alarm for 11 am today"), "already past: the model asks")
        XCTAssertNil(match("wake me up at 6:30 and turn the flashlight off"))
    }

    // MARK: Flashlight, brightness, volume, Do Not Disturb

    func testFlashlight() {
        XCTAssertEqual(match("flashlight on"), tool("phone_flashlight", ["on": .bool(true)]))
        XCTAssertEqual(match("Turn off the torch"), tool("phone_flashlight", ["on": .bool(false)]))
        XCTAssertEqual(match("turn the flashlight on!"), tool("phone_flashlight", ["on": .bool(true)]))
        XCTAssertNil(match("is my flashlight on"))
        XCTAssertNil(match("turn on the flashlight and set a timer for 5 minutes"))
    }

    func testBrightness() {
        XCTAssertEqual(match("brightness 50%"), tool("phone_brightness", ["percent": .int(50)]))
        XCTAssertEqual(match("set the screen brightness to max"), tool("phone_brightness", ["percent": .int(100)]))
        XCTAssertEqual(match("Brightness to 40 percent"), tool("phone_brightness", ["percent": .int(40)]))
        XCTAssertEqual(match("turn brightness down to minimum"), tool("phone_brightness", ["percent": .int(0)]))
        XCTAssertNil(match("brightness 150%"))
        XCTAssertNil(match("make the screen brighter"), "no level: the model's")
    }

    func testVolumeAndDoNotDisturbAnswerHonestly() {
        XCTAssertEqual(match("set the volume to 30%"), .answer(PhoneCommands.volumeAnswer))
        XCTAssertEqual(match("turn the ringer volume up"), .answer(PhoneCommands.volumeAnswer))
        XCTAssertEqual(match("volume down"), .answer(PhoneCommands.volumeAnswer))
        XCTAssertEqual(match("Turn on Do Not Disturb"), .answer(PhoneCommands.doNotDisturbAnswer))
        XCTAssertEqual(match("dnd off"), .answer(PhoneCommands.doNotDisturbAnswer))
        XCTAssertTrue(PhoneCommands.volumeAnswer.contains("Control Center"))
        XCTAssertTrue(PhoneCommands.doNotDisturbAnswer.contains("Focus"))
        XCTAssertNil(match("what does do not disturb do"))
        XCTAssertNil(match("why is the volume so low"))
    }

    // MARK: Reminders

    private func reminder(_ title: String, _ due: String) -> DirectCommand {
        tool("reminders", ["action": .string("create"), "title": .string(title), "due": .string(due)])
    }

    func testRemindersAtATime() {
        XCTAssertEqual(match("remind me at 5 pm to call Mom"), reminder("call Mom", "2026-11-12 17:00"))
        XCTAssertEqual(match("Remind me to call the bank tomorrow at 9 am"), reminder("call the bank", "2026-11-13 09:00"))
        XCTAssertEqual(match("remind me to water the plants tonight at 8"), reminder("water the plants", "2026-11-12 20:00"))
    }

    func testRemindersInAWhile() {
        XCTAssertEqual(match("remind me in 20 minutes to check the oven"), reminder("check the oven", "2026-11-12 14:20"))
        XCTAssertEqual(match("remind me to stretch in half an hour"), reminder("stretch", "2026-11-12 14:30"))
    }

    func testReminderWithNoAmOrPmIsTheNextOne() {
        // 14:00 now: "at 5" is 5 PM today; "at 1" is 1 AM tomorrow, before 1 PM tomorrow.
        XCTAssertEqual(match("remind me at 5 to stretch"), reminder("stretch", "2026-11-12 17:00"))
        XCTAssertEqual(match("remind me at 1 to stretch"), reminder("stretch", "2026-11-13 01:00"))
    }

    func testReminderNearMissesFallThrough() {
        XCTAssertNil(match("remind me tomorrow at 9 to call Mom"), "a day with no AM or PM is the model's")
        XCTAssertNil(match("remind me what a haiku is"))
        XCTAssertNil(match("remind me about the meeting on Monday"))
        XCTAssertNil(match("remind me at 2 pm today to call Mom"), "already past")
    }

    func testListAndCancelReminders() {
        XCTAssertEqual(match("What are my reminders?"), tool("reminders", ["action": .string("list")]))
        XCTAssertEqual(match("do I have any reminders"), tool("reminders", ["action": .string("list")]))
        XCTAssertEqual(match("Cancel my reminder to call Mom"),
                       tool("reminders", ["action": .string("cancel"), "title": .string("call Mom")]))
    }

    // MARK: Calls, directions, apps

    func testCalls() {
        let call = { (who: String) in
            self.tool("contact_action", ["action": .string("call"), "contact": .string(who)])
        }
        XCTAssertEqual(match("call 555-0123"), call("555-0123"))
        XCTAssertEqual(match("Call Mom"), call("Mom"))
        XCTAssertEqual(match("call my mom"), call("mom"))
        XCTAssertEqual(match("call Maya Patel"), call("Maya Patel"))
    }

    func testCallNearMissesFallThrough() {
        XCTAssertNil(match("call me Sam"))
        XCTAssertNil(match("call it a day"))
        XCTAssertNil(match("call mom back"))
        XCTAssertNil(match("call mom and tell her I'm late"))
    }

    func testDirections() {
        XCTAssertEqual(match("Navigate to Golden Gate Park"),
                       tool("phone_navigate", ["destination": .string("Golden Gate Park")]))
        XCTAssertEqual(match("directions to the airport"),
                       tool("phone_navigate", ["destination": .string("the airport")]))
        XCTAssertNil(match("directions to the airport and then lunch"))
    }

    func testOpenKnownAppsOnly() {
        XCTAssertEqual(match("open Spotify"), tool("phone_open_app", ["name": .string("Spotify")]))
        XCTAssertEqual(match("launch apple maps"), tool("phone_open_app", ["name": .string("Maps")]))
        XCTAssertEqual(match("open the Notes app"), tool("phone_open_app", ["name": .string("Notes")]))
        XCTAssertNil(match("open the door"))
        XCTAssertNil(match("start a conversation"))
    }

    func testOrdinaryMessagesFallThrough() {
        XCTAssertNil(match("hello"))
        XCTAssertNil(match("what time is it"))
        XCTAssertNil(match(""))
        XCTAssertNil(match("flashlight on\nand also brightness 50%"))
    }
}
