import XCTest
@testable import Anu

/// "Brief me" from chat: the Daily Brief as a broker read, run by the Direct
/// tier with no model.
@MainActor
final class DailyBriefToolTests: XCTestCase {
    private struct Source: DailyBriefCalendarSource {
        var events: [DailyBrief.Event] = []
        var reminders: [DailyBrief.Reminder] = []
        func events(on day: Date, calendar: Calendar) async -> Result<[DailyBrief.Event], BriefSourceProblem> { .success(events) }
        func reminders(dueBy day: Date, calendar: Calendar) async -> Result<[DailyBrief.Reminder], BriefSourceProblem> { .success(reminders) }
    }

    private let noon = Date(timeIntervalSince1970: 1_794_571_200)   // 2026-11-13 12:00 UTC

    private func tool(_ source: Source) -> DailyBriefTool {
        var tool = DailyBriefTool()
        tool.source = source
        let fixed = noon
        tool.now = { fixed }
        return tool
    }

    func testWholeBriefRequestsAreDirectCommands() {
        for text in ["Brief me", "brief me.", "My daily brief", "daily brief", "Give me my morning brief",
                     "What's my day look like?", "How's my day looking", "what does my day look like today",
                     "brief me on my day"] {
            XCTAssertEqual(PhoneCommands.match(text), .tool(name: "daily_brief", arguments: .object([:])), text)
        }
    }

    func testNearMissesGoToTheModel() {
        for text in ["a brief history of time", "brief me on the french revolution", "write a brief summary of this",
                     "what's my day job called", "brief"] {
            XCTAssertNotEqual(PhoneCommands.match(text), .tool(name: "daily_brief", arguments: .object([:])), text)
        }
    }

    func testToolReturnsTodaysEventsAndReminders() async throws {
        let event = DailyBrief.Event(title: "Dentist", start: noon.addingTimeInterval(3_600),
                                     end: noon.addingTimeInterval(5_400), allDay: false, location: nil)
        let reminder = DailyBrief.Reminder(title: "Pay rent", due: noon, overdue: false)
        let text = try await tool(Source(events: [event], reminders: [reminder])).execute(arguments: .object([:]))
        XCTAssertTrue(text.hasPrefix("Today is"), text)
        XCTAssertTrue(text.contains("Dentist"), text)
        XCTAssertTrue(text.contains("Pay rent"), text)
    }

    func testAnEmptyDaySaysSo() async throws {
        let text = try await tool(Source()).execute(arguments: .object([:]))
        XCTAssertTrue(text.contains("Calendar: nothing today."), text)
    }

    func testBriefMeRunsWithNoModelAndAReceipt() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brief-\(UUID().uuidString)", isDirectory: true)
        let model = QueuedMockModel([])
        let orch = AgentOrchestrator(model: model, sessionsDirectory: dir)
        orch.toolRegistry.register(tool(Source(events: [DailyBrief.Event(
            title: "Standup", start: noon, end: noon.addingTimeInterval(900), allDay: false, location: nil)])))

        await orch.run(userMessage: "Brief me")

        XCTAssertTrue(model.capturedPrompts.isEmpty, "no model call")
        XCTAssertEqual(orch.messages.first { $0.role == .toolCall }?.toolCall?.name, "daily_brief")
        let answer = orch.messages.last { $0.role == .assistant }
        XCTAssertEqual(answer?.label, AgentOrchestrator.directLabel)
        XCTAssertTrue(answer?.content.contains("Standup") == true, answer?.content ?? "")
        XCTAssertNil(answer?.receipts, "a read gets no receipt; receipts list actions")
    }

    func testTheSelectorOffersItWhenAskedAboutTheDay() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brief-\(UUID().uuidString)", isDirectory: true)
        let orch = AgentOrchestrator(model: QueuedMockModel([]), sessionsDirectory: dir)
        let names = ToolSelector.select(orch.toolRegistry.allTools,
                                        turns: ["anything I should know about today before my morning?"],
                                        escalation: nil).map(\.name)
        XCTAssertTrue(names.contains("daily_brief"), "\(names)")
    }
}
