import XCTest
@testable import Anu

/// Tests the LLM-as-router escalation path: the pure decision parser, the
/// eligibility gate, and the orchestrator's bounded on-device judge.
final class EscalationRouterTests: XCTestCase {

    func testShouldEscalateParsesDecision() {
        XCTAssertTrue(EscalationRouter.shouldEscalate(from: "ESCALATE"))
        XCTAssertTrue(EscalationRouter.shouldEscalate(from: "escalate\n"))
        XCTAssertTrue(EscalationRouter.shouldEscalate(from: "Escalate — needs a bigger model"))

        XCTAssertFalse(EscalationRouter.shouldEscalate(from: "LOCAL"))
        XCTAssertFalse(EscalationRouter.shouldEscalate(from: "local, this is simple"))
        XCTAssertFalse(EscalationRouter.shouldEscalate(from: ""))
        XCTAssertFalse(EscalationRouter.shouldEscalate(from: "   "))
        XCTAssertFalse(EscalationRouter.shouldEscalate(from: "I'm not sure"))
    }

    func testShouldEscalateStaysLocalOnNegatedOutput() {
        // Small models don't always obey "one word" — negated phrasings that
        // contain "escalate" must NOT trigger a spurious cloud call.
        XCTAssertFalse(EscalationRouter.shouldEscalate(from: "do not escalate"))
        XCTAssertFalse(EscalationRouter.shouldEscalate(from: "No need to escalate this."))
        XCTAssertFalse(EscalationRouter.shouldEscalate(from: "I don't think we should escalate"))
        XCTAssertFalse(EscalationRouter.shouldEscalate(from: "LOCAL — no need to escalate"))
        XCTAssertFalse(EscalationRouter.shouldEscalate(from: "This doesn't need to escalate"))
        XCTAssertFalse(EscalationRouter.shouldEscalate(from: "can't escalate, too simple"))

        // Genuine escalations still read as ESCALATE.
        XCTAssertTrue(EscalationRouter.shouldEscalate(from: "please escalate"))
        XCTAssertTrue(EscalationRouter.shouldEscalate(from: "Yes, escalate this to the bigger model"))
        XCTAssertTrue(EscalationRouter.shouldEscalate(from: "I would escalate"))
    }

    func testSystemPromptCarriesSentinelAndOptions() {
        let prompt = EscalationRouter.systemPrompt()
        XCTAssertTrue(prompt.contains("[[ROUTER]]"))
        XCTAssertTrue(prompt.contains("LOCAL"))
        XCTAssertTrue(prompt.contains("ESCALATE"))
    }

    func testIsJudgeEligibleSkipsOnlyChatAndMath() {
        // The two buckets a small model reliably owns — don't spend a call.
        XCTAssertFalse(AgentOrchestrator.isJudgeEligible(.init(type: .casualChat, confidence: 0.9)))
        XCTAssertFalse(AgentOrchestrator.isJudgeEligible(.init(type: .math, confidence: 0.9)))
        // Everything else is worth a second opinion — including web/factual
        // lookups, where a 4B model is least reliable ("Tv9 vs ntv").
        XCTAssertTrue(AgentOrchestrator.isJudgeEligible(.init(type: .webInfo, confidence: 0.9)))
        XCTAssertTrue(AgentOrchestrator.isJudgeEligible(.init(type: .generalQA, confidence: 0.9)))
        XCTAssertTrue(AgentOrchestrator.isJudgeEligible(.init(type: .codeGen, confidence: 0.9)))
        XCTAssertTrue(AgentOrchestrator.isJudgeEligible(.init(type: .longWriting, confidence: 0.9)))
        // Low-confidence guesses are always eligible regardless of type.
        XCTAssertTrue(AgentOrchestrator.isJudgeEligible(.init(type: .casualChat, confidence: 0.2)))
        XCTAssertTrue(AgentOrchestrator.isJudgeEligible(.init(type: .math, confidence: 0.2)))
    }

    @MainActor
    func testJudgeEscalationReflectsOnDeviceModelDecision() async {
        let escalateModel = QueuedMockModel(["ESCALATE"])
        let orchA = AgentOrchestrator(model: escalateModel)
        let escalate = await orchA.judgeEscalation("write a 2000-word treatise on category theory")
        XCTAssertTrue(escalate)

        let localModel = QueuedMockModel(["LOCAL"])
        let orchB = AgentOrchestrator(model: localModel)
        let stayLocal = await orchB.judgeEscalation("hi there")
        XCTAssertFalse(stayLocal)
    }

    @MainActor
    func testJudgeEscalationFailsSafeToLocal() async {
        // Empty output (e.g. the model produced nothing) must stay LOCAL — the
        // judge can never force an escalation it wasn't clearly asked for.
        let empty = AgentOrchestrator(model: QueuedMockModel([""]))
        let e1 = await empty.judgeEscalation("write a 2000-word treatise on category theory")
        XCTAssertFalse(e1, "empty judge output should fail safe to LOCAL")

        // Ambiguous, non-committal output must also stay LOCAL.
        let vague = AgentOrchestrator(model: QueuedMockModel(["hmm, hard to say"]))
        let e2 = await vague.judgeEscalation("explain this to me")
        XCTAssertFalse(e2, "ambiguous judge output should fail safe to LOCAL")
    }
}
