import XCTest
@testable import Anu

/// Covers the per-sandbox partitioning added to the privacy ledger.
@MainActor
final class PrivacyLedgerSessionTests: XCTestCase {

    func testEventsPartitionBySession() {
        let ledger = PrivacyLedger(persists: false)
        let a = UUID(), b = UUID()

        ledger.setActiveSession(a)
        ledger.beginTurn()
        ledger.record(destination: .cloud(model: "x"), payload: "from A", redactions: 0)

        ledger.setActiveSession(b)
        ledger.beginTurn()
        ledger.record(destination: .cloud(model: "x"), payload: "from B", redactions: 0)

        XCTAssertEqual(ledger.eventsForSession(a).count, 1)
        XCTAssertEqual(ledger.eventsForSession(b).count, 1)
        XCTAssertEqual(ledger.eventsForSession(a).first?.payloadSummary, "from A")
    }

    func testPerSessionTurnCountersAreIndependent() {
        let ledger = PrivacyLedger(persists: false)
        let a = UUID(), b = UUID()

        ledger.setActiveSession(a)
        XCTAssertEqual(ledger.beginTurn(), 1)
        XCTAssertEqual(ledger.beginTurn(), 2)

        ledger.setActiveSession(b)
        XCTAssertEqual(ledger.beginTurn(), 1, "a fresh sandbox starts its own turn count")

        ledger.setActiveSession(a)
        XCTAssertEqual(ledger.currentTurn, 2, "switching back resumes the prior count")
    }

    func testClearSessionDropsOnlyThatSession() {
        let ledger = PrivacyLedger(persists: false)
        let a = UUID(), b = UUID()

        ledger.setActiveSession(a); ledger.beginTurn()
        ledger.record(destination: .cloud(model: "x"), payload: "A", redactions: 0)
        ledger.setActiveSession(b); ledger.beginTurn()
        ledger.record(destination: .cloud(model: "x"), payload: "B", redactions: 0)

        ledger.clearSession(a)
        XCTAssertTrue(ledger.eventsForSession(a).isEmpty)
        XCTAssertEqual(ledger.eventsForSession(b).count, 1)
    }

    func testLastTurnSummaryScopedToActiveSession() {
        let ledger = PrivacyLedger(persists: false)
        let a = UUID(), b = UUID()

        ledger.setActiveSession(a); ledger.beginTurn()
        ledger.record(destination: .cloud(model: "x"), payload: "secret", redactions: 2)

        ledger.setActiveSession(b); ledger.beginTurn()   // a turn that sends nothing off-device
        XCTAssertEqual(ledger.lastTurnSummary?.offDeviceEvents, 0,
                       "B's last turn sent nothing off-device")
    }

    /// Older ledgers had no `sessionId`; nil optionals are omitted on encode, so
    /// such files must still decode (read back as `nil`).
    func testEventWithoutSessionIdDecodes() throws {
        let original = PrivacyEvent(turn: 1, destination: .cloud(model: "gemini"),
                                    payloadSummary: "hi", redactions: 0, byteCount: 2)
        XCTAssertNil(original.sessionId)

        let data = try JSONEncoder().encode(original)
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("sessionId"),
                       "nil sessionId should be omitted, mimicking a pre-multi-session file")

        let decoded = try JSONDecoder().decode(PrivacyEvent.self, from: data)
        XCTAssertNil(decoded.sessionId)
    }
}
