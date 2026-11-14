import Foundation
#if os(iOS)
import UIKit
#endif

// MARK: - Heat and battery guard (Android parity #23, ADR-072)
//
// While the phone is warm, or the battery is low and not charging, a turn takes
// the lighter path: the multi-call planner and the on-device escalation judge
// are skipped, on-device answers are kept short, and nothing moves to the
// cloud by itself. A request the classifier already sent to the cloud stays
// there, since that costs the phone nothing.

/// What the guard reads from the device. Injected, so tests can fake it.
struct DeviceConditions: Equatable, Sendable {
    enum Thermal: Int, Sendable, Comparable {
        case nominal, fair, serious, critical

        static func < (lhs: Thermal, rhs: Thermal) -> Bool { lhs.rawValue < rhs.rawValue }

        init(_ state: ProcessInfo.ThermalState) {
            switch state {
            case .nominal: self = .nominal
            case .fair: self = .fair
            case .serious: self = .serious
            case .critical: self = .critical
            @unknown default: self = .serious
            }
        }
    }

    var thermal: Thermal
    /// 0 to 1, or nil when unknown (the simulator, a Mac without a battery).
    var batteryLevel: Double?
    /// Charging or full on the charger. Unknown counts as charging, so a
    /// device that can't say is never guarded for its battery.
    var charging: Bool

    static let normal = DeviceConditions(thermal: .nominal, batteryLevel: nil, charging: true)
}

@MainActor
protocol DeviceConditionsProviding: AnyObject {
    func current() -> DeviceConditions
}

/// Reads `ProcessInfo.thermalState` and, on iOS, `UIDevice`'s battery.
@MainActor
final class SystemDeviceConditions: DeviceConditionsProviding {
    func current() -> DeviceConditions {
        let thermal = DeviceConditions.Thermal(ProcessInfo.processInfo.thermalState)
        #if os(iOS)
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let level = device.batteryLevel
        let charging: Bool
        switch device.batteryState {
        case .unplugged: charging = false
        case .charging, .full, .unknown: charging = true
        @unknown default: charging = true
        }
        return DeviceConditions(thermal: thermal, batteryLevel: level < 0 ? nil : Double(level), charging: charging)
        #else
        return DeviceConditions(thermal: thermal, batteryLevel: nil, charging: true)
        #endif
    }
}

/// Why the phone is guarded (Android's `Guard`).
enum DeviceGuard: String, Equatable, Sendable {
    case heat
    case battery

    /// The quiet line that says what the guard changed (design review D22).
    var note: String {
        switch self {
        case .heat: return "Lighter path while the phone is warm"
        case .battery: return "Kept short to save battery"
        }
    }

    /// Low battery: this fraction or less, and not charging (ADR-072: 15%).
    static let lowBattery = 0.15
    /// The longest on-device answer while guarded, in tokens (ADR-072: 256).
    static let answerTokens = 256

    /// Heat first: `.serious` or `.critical` thermal state. Then a battery at
    /// 15% or less that isn't charging. Nil when neither.
    static func evaluate(_ conditions: DeviceConditions) -> DeviceGuard? {
        if conditions.thermal >= .serious { return .heat }
        if let level = conditions.batteryLevel, level <= lowBattery, !conditions.charging { return .battery }
        return nil
    }
}

/// What a turn may do, after the guard. Pure, so the decision is unit-tested.
struct GuardPlan: Equatable, Sendable {
    let guarding: DeviceGuard?
    /// The opt-in Planner→Executor→Critic pipeline (8 to 16 model calls).
    let allowPlanner: Bool
    /// The on-device escalation judge: an extra model call, and the only way a
    /// turn moves to the cloud by itself.
    let allowEscalationJudge: Bool
    /// A cap on on-device answer tokens, or nil for the usual budget.
    let maxOutputTokens: Int?

    static func make(_ guarding: DeviceGuard?) -> GuardPlan {
        GuardPlan(
            guarding: guarding,
            allowPlanner: guarding == nil,
            allowEscalationJudge: guarding == nil,
            maxOutputTokens: guarding == nil ? nil : DeviceGuard.answerTokens)
    }
}

extension GenerationConfig {
    /// This config with at most `cap` new tokens; unchanged when `cap` is nil.
    func capped(_ cap: Int?) -> GenerationConfig {
        guard let cap, cap < maxNewTokens else { return self }
        var config = self
        config.maxNewTokens = cap
        return config
    }
}
