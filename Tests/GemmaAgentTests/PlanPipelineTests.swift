import XCTest
@testable import GemmaAgent

@MainActor
final class PlanPipelineTests: XCTestCase {

    /// Full two-step pipeline: plan → researcher → writer → synthesis → critic
    /// (approved). Verifies the scratchpad is threaded, sub-agent work stays
    /// headless, and only the final answer reaches the chat/history.
    func testEndToEndApprovedPath() async {
        let model = QueuedMockModel([
            // 1) planner
            #"{"plan":[{"step":1,"description":"research the topic","specialist":"researcher"},{"step":2,"description":"write it up","specialist":"writer"}]}"#,
            // 2) sub-agent step 1 (answers directly, no tool)
            "Found the relevant facts.",
            // 3) sub-agent step 2
            "Drafted the summary.",
            // 4) synthesis draft
            "The final combined answer.",
            // 5) critic
            #"{"verdict":"approved"}"#,
        ])
        let orch = AgentOrchestrator(model: model)
        await orch.planPipeline(goal: "research the topic and then write it up", memoryContext: nil)

        // Exactly five model calls were made, in order.
        XCTAssertEqual(model.capturedPrompts.count, 5)
        XCTAssertTrue(model.capturedPrompts[0].contains("[[PLANNER]]"))
        XCTAssertTrue(model.capturedPrompts[1].contains("[[SUBAGENT:researcher]]"))
        XCTAssertTrue(model.capturedPrompts[2].contains("[[SUBAGENT:writer]]"))
        XCTAssertTrue(model.capturedPrompts[3].contains("[[SYNTH]]"))
        XCTAssertTrue(model.capturedPrompts[4].contains("[[CRITIC]]"))

        // Scratchpad threaded into synthesis.
        XCTAssertTrue(model.capturedPrompts[3].contains("Found the relevant facts."))
        XCTAssertTrue(model.capturedPrompts[3].contains("Drafted the summary."))

        // No sub-agent tool bubbles leaked into the chat.
        XCTAssertFalse(orch.messages.contains { $0.role == .toolCall || $0.role == .toolResult })

        // Exactly one assistant bubble — the final answer — and it's finalized.
        let assistants = orch.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistants.count, 1)
        XCTAssertEqual(assistants.first?.content, "The final combined answer.")
        XCTAssertEqual(assistants.first?.isStreaming, false)

        // Conversation history carries only the final answer, not intermediates.
        XCTAssertEqual(orch.conversationHistory.count, 1)
        XCTAssertEqual(orch.conversationHistory.first?.content, "The final combined answer.")

        // Trace shows the plan and the critic verdict.
        XCTAssertTrue(orch.reasoningSteps.first?.thought.hasPrefix("Plan:") ?? false)
        XCTAssertTrue(orch.reasoningSteps.contains { $0.action == "Approved" })
    }

    /// Single-step plan whose draft the critic asks to revise once. Verifies the
    /// revision happens exactly once and the revised text is what ships.
    func testSingleStepRevisePath() async {
        let model = QueuedMockModel([
            // 1) planner — one generalist step
            #"{"plan":[{"step":1,"description":"answer it","specialist":"generalist"}]}"#,
            // 2) sub-agent draft
            "A first draft answer.",
            // 3) critic asks for one revision
            #"{"verdict":"revise","instruction":"add a conclusion"}"#,
            // 4) revision
            "The revised final answer with a conclusion.",
        ])
        let orch = AgentOrchestrator(model: model)
        await orch.planPipeline(goal: "answer this single thing", memoryContext: nil)

        // Single-step plans skip the separate synthesis call: planner + sub-agent
        // + critic + one revision == 4 calls.
        XCTAssertEqual(model.capturedPrompts.count, 4)
        XCTAssertTrue(model.capturedPrompts[3].contains("[[SYNTH]]")) // revision uses the synth persona

        let assistants = orch.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistants.count, 1)
        XCTAssertEqual(assistants.first?.content, "The revised final answer with a conclusion.")
        XCTAssertTrue(orch.reasoningSteps.contains { ($0.action ?? "").hasPrefix("Revise:") })
    }

    /// run() must engage the pipeline for a clearly multi-step request.
    func testRunEngagesPipelineForMultiStep() async {
        let model = QueuedMockModel([
            #"{"plan":[{"step":1,"description":"add 5 and 5","specialist":"mathematician"},{"step":2,"description":"add 6 and 6","specialist":"mathematician"}]}"#,
            "10",
            "12",
            "The totals are 10 and 12.",
            #"{"verdict":"approved"}"#,
        ])
        let orch = AgentOrchestrator(model: model)
        await orch.run(userMessage: "calculate 5 plus 5 and then calculate 6 plus 6 for me")

        XCTAssertTrue(orch.reasoningSteps.contains { $0.thought.hasPrefix("Plan:") },
                      "the multi-step request should have engaged the planner")
        XCTAssertFalse(orch.isThinking)
        XCTAssertEqual(orch.status, .idle)
    }
}
