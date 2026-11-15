import XCTest
@testable import Anu

/// The heat and battery guard (Android parity #23, ADR-072).
final class DeviceGuardTests: XCTestCase {
    private func conditions(_ thermal: DeviceConditions.Thermal, battery: Double? = nil, charging: Bool = true) -> DeviceConditions {
        DeviceConditions(thermal: thermal, batteryLevel: battery, charging: charging)
    }

    func testHeatGuardsAtSeriousAndCritical() {
        XCTAssertNil(DeviceGuard.evaluate(conditions(.nominal)))
        XCTAssertNil(DeviceGuard.evaluate(conditions(.fair)))
        XCTAssertEqual(DeviceGuard.evaluate(conditions(.serious)), .heat)
        XCTAssertEqual(DeviceGuard.evaluate(conditions(.critical)), .heat)
    }

    func testLowBatteryGuardsOnlyWhenNotCharging() {
        XCTAssertEqual(DeviceGuard.evaluate(conditions(.nominal, battery: 0.15, charging: false)), .battery)
        XCTAssertEqual(DeviceGuard.evaluate(conditions(.nominal, battery: 0.05, charging: false)), .battery)
        XCTAssertNil(DeviceGuard.evaluate(conditions(.nominal, battery: 0.15, charging: true)))
        XCTAssertNil(DeviceGuard.evaluate(conditions(.nominal, battery: 0.16, charging: false)))
        XCTAssertNil(DeviceGuard.evaluate(conditions(.nominal, battery: nil, charging: false)), "unknown is never low")
    }

    func testHeatComesFirst() {
        XCTAssertEqual(DeviceGuard.evaluate(conditions(.critical, battery: 0.05, charging: false)), .heat)
    }

    func testThermalStateMapping() {
        XCTAssertEqual(DeviceConditions.Thermal(.nominal), .nominal)
        XCTAssertEqual(DeviceConditions.Thermal(.fair), .fair)
        XCTAssertEqual(DeviceConditions.Thermal(.serious), .serious)
        XCTAssertEqual(DeviceConditions.Thermal(.critical), .critical)
    }

    func testPlanSkipsHeavyStepsAndShortensAnswersWhileGuarded() {
        XCTAssertEqual(GuardPlan.make(nil),
                       GuardPlan(guarding: nil, allowPlanner: true, allowEscalationJudge: true, maxOutputTokens: nil))
        for guarding in [DeviceGuard.heat, .battery] {
            let plan = GuardPlan.make(guarding)
            XCTAssertFalse(plan.allowPlanner)
            XCTAssertFalse(plan.allowEscalationJudge, "nothing moves to the cloud by itself while guarded")
            XCTAssertEqual(plan.maxOutputTokens, 256)
        }
        XCTAssertEqual(DeviceGuard.heat.note, "Lighter path while the phone is warm")
        XCTAssertEqual(DeviceGuard.battery.note, "Kept short to save battery")
    }

    func testCappedConfig() {
        let base = GenerationConfig.default
        XCTAssertEqual(base.capped(nil).maxNewTokens, base.maxNewTokens)
        XCTAssertEqual(base.capped(256).maxNewTokens, min(256, base.maxNewTokens))
        XCTAssertEqual(base.capped(100_000).maxNewTokens, base.maxNewTokens, "a cap never raises the budget")
    }
}
