import XCTest
@testable import Anu

/// AI Email and AI Scheduling skill detection and tool bundles (Android
/// parity #11). Cases follow Anu Android's RouterTest.
@MainActor
final class SkillDetectorTests: XCTestCase {
    func testEmailWords() {
        XCTAssertEqual(SkillDetector.detect("Anything important in my inbox?"), .email)
        XCTAssertEqual(SkillDetector.detect("Draft an email to Maya about the message she sent"), .email)
        XCTAssertEqual(SkillDetector.detect("Reply to Maya's email and suggest Thursday"), .email)
        XCTAssertEqual(SkillDetector.detect("Set an alarm and email Maya the agenda"), .email)
        XCTAssertEqual(SkillDetector.detect("Reply to her that 7 works"), .email, "a reply means email unless the chat was texts")
        XCTAssertEqual(SkillDetector.detect("Reply to Raj that 2026-09-26 works for the offsite"), .email, "a date isn't a phone number")
    }

    func testSchedulingWords() {
        XCTAssertEqual(SkillDetector.detect("Book a meeting with Raj on Monday"), .scheduling)
        XCTAssertEqual(SkillDetector.detect("What's on my calendar today?"), .scheduling)
        XCTAssertEqual(SkillDetector.detect("Add a note to my 3pm meeting on the calendar"), .scheduling)
        XCTAssertEqual(SkillDetector.detect("Remind me about the meeting with Raj on Monday"), .scheduling)
        XCTAssertEqual(SkillDetector.detect("Am I free Thursday afternoon? Find a free slot"), .scheduling)
    }

    func testOtherAreasAreNotEmailOrScheduling() {
        XCTAssertEqual(SkillDetector.detect("Remember Maya's email is maya@example.com"), .other, "memory comes first")
        XCTAssertEqual(SkillDetector.detect("In the Gmail app, archive the newsletter"), .other, "tapping in another app")
        XCTAssertEqual(SkillDetector.detect("What's on my groceries note?"), .other)
        XCTAssertEqual(SkillDetector.detect("Text Maya I'm late"), .messages)
        XCTAssertEqual(SkillDetector.detect("Reply to +1 415 555 0134 that I'm on my way"), .messages)
        XCTAssertEqual(SkillDetector.detect("What is the capital of France?"), .chat)
        XCTAssertEqual(SkillDetector.detect("hello there"), .chat)
    }

    func testFollowUpsKeepTheSkill() {
        XCTAssertEqual(SkillDetector.detect("Yes, send it", previous: .email), .email)
        XCTAssertEqual(SkillDetector.detect("Reply to her that 7 works", previous: .messages), .messages)
        let meeting = "Set up a meeting with Raj next week"
        XCTAssertEqual(SkillDetector.detect(turns: [meeting, "How about Friday?"]), .scheduling)
        XCTAssertEqual(SkillDetector.detect(turns: [meeting, "What time works for him?"]), .scheduling)
        XCTAssertEqual(SkillDetector.detect(turns: [meeting, "Why?"]), .scheduling)
        XCTAssertEqual(SkillDetector.detect(turns: ["Anything from Raj in my inbox?", "Reply that 1 works"]), .email)
    }

    func testAStandaloneQuestionOrTooManyFollowUpsEndTheSkill() {
        XCTAssertEqual(SkillDetector.detect(turns: ["Check my inbox", "Who wrote Pride and Prejudice?"]), .chat)
        XCTAssertEqual(SkillDetector.detect(turns: ["Check my inbox", "ok", "yes", "sure", "go on"]), .chat,
                       "a skill carries at most three follow-ups")
        XCTAssertEqual(SkillDetector.detect(turns: ["Check my inbox", "ok", "yes", "sure"]), .email)
    }

    // MARK: Bundles

    private struct Named: Tool {
        let name: String
        let description = "stub"
        var parameters: JSONSchema? { nil }
        func execute(arguments: JSONValue) async throws -> String { name }
    }

    private let registered: [any Tool] = (GmailTools.names + ["calculator", "calendar", "contacts", "datetime", "reminders", "web_search"])
        .map { Named(name: $0) }

    func testEmailBundle() {
        XCTAssertEqual(SkillDetector.tools(for: .email, from: registered).map(\.name),
                       ["gmail_search", "gmail_read_thread", "gmail_create_draft", "gmail_send", "contacts", "calendar", "datetime"])
    }

    func testSchedulingBundle() {
        XCTAssertEqual(SkillDetector.tools(for: .scheduling, from: registered).map(\.name), ["calendar", "contacts", "datetime"])
    }

    func testOtherTurnsNeverSeeGmailTools() {
        let names = SkillDetector.tools(for: .chat, from: registered).map(\.name)
        XCTAssertEqual(Set(names), ["calculator", "calendar", "contacts", "datetime", "reminders", "web_search"])
        XCTAssertTrue(SkillDetector.needsTools(.email))
        XCTAssertFalse(SkillDetector.needsTools(.chat))
    }

    // MARK: Orchestrator hook

    func testEmailTurnRunsOnTheAgentPathWithTheEmailBundle() async {
        UserDefaults.standard.removeObject(forKey: "fast_mode")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skill-\(UUID().uuidString)", isDirectory: true)
        let orch = AgentOrchestrator(model: ScriptedModel(), sessionsDirectory: dir)
        await orch.run(userMessage: "Anything from Maya in my inbox this week?")
        XCTAssertEqual(orch.currentSkill, .email)
        XCTAssertEqual(orch.toolsForCurrentTurn.map(\.name),
                       ["gmail_search", "gmail_read_thread", "gmail_create_draft", "gmail_send", "contacts", "calendar", "datetime"])
        XCTAssertTrue(orch.reasoningSteps.contains { $0.action == "Route → on-device (agent + tools)" },
                      "\(orch.reasoningSteps.map { $0.action ?? "" })")

        await orch.run(userMessage: "What is the capital of France?")
        XCTAssertEqual(orch.currentSkill, .chat, "a question that stands alone ends the email skill")
        XCTAssertFalse(orch.toolsForCurrentTurn.contains { $0.name.hasPrefix("gmail_") })
    }
}
