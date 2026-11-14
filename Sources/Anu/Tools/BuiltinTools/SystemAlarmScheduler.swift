import Foundation
import os

/// The timer and alarm scheduler the app uses (Android parity #16, ADR-076).
///
/// On an iPhone with AlarmKit (iOS 26.1 and later) and the user's permission,
/// a timer or alarm is a real system alarm: it rings through silent mode and
/// Focus and shows on the Lock Screen, like one from the Clock app. Anywhere
/// else, or when AlarmKit says no, it falls back to a local notification and
/// says so, with the reason, so the answer never calls a notification an
/// alarm. Every step is logged (subsystem com.anu.app, category Alarms).
struct SystemAlarmScheduler: ReportingTimerScheduling {
    let fallback: any TimerScheduling
    static let log = Logger(subsystem: "com.anu.app", category: "Alarms")

    init(fallback: any TimerScheduling) {
        self.fallback = fallback
    }

    func schedule(label: String, at date: Date) async -> Bool {
        await schedule(label: label, at: date, kind: .alarm)
    }

    func schedule(label: String, at date: Date, kind: TimerKind) async -> Bool {
        switch await scheduleReporting(label: label, at: date, kind: kind) {
        case .ringing, .notification, .scheduled: return true
        case .failed: return false
        }
    }

    func scheduleReporting(label: String, at date: Date, kind: TimerKind) async -> ScheduleOutcome {
        var why = "this device can't set system alarms."
        #if os(iOS) && canImport(AlarmKit)
        if #available(iOS 26.1, *) {
            switch await AlarmKitBridge.schedule(label: label, at: date) {
            case .scheduled: return .ringing
            case .refused(let reason): why = reason
            }
        }
        #endif
        Self.log.notice("AlarmKit didn't take it (\(why, privacy: .public)); using a notification")
        guard await fallback.schedule(label: label, at: date, kind: kind) else {
            return .failed("Couldn't set the \(kind.rawValue): Alarms and Notifications are both off for Anu (Settings → Anu).")
        }
        return .notification(why: why)
    }
}

/// AlarmKit's permission, for Settings: nil where AlarmKit isn't available.
enum AlarmPermission {
    case notAsked, allowed, denied

    static var current: AlarmPermission? {
        #if os(iOS) && canImport(AlarmKit)
        if #available(iOS 26.1, *) {
            switch AlarmManager.shared.authorizationState {
            case .authorized: return .allowed
            case .denied: return .denied
            case .notDetermined: return .notAsked
            @unknown default: return .notAsked
            }
        }
        #endif
        return nil
    }

    /// The alarms AlarmKit holds for Anu, one line each (for the debug export).
    static func scheduledSummaries() -> [String] {
        #if os(iOS) && canImport(AlarmKit)
        if #available(iOS 26.1, *) {
            do {
                return try AlarmManager.shared.alarms.map { "\($0.id) \(String(describing: $0.state)) \(String(describing: $0.schedule))" }
            } catch {
                return ["couldn't list alarms: \(String(describing: error))"]
            }
        }
        #endif
        return []
    }

    /// Asks once (iOS shows the prompt only the first time) and returns the answer.
    @discardableResult
    static func request() async -> AlarmPermission? {
        #if os(iOS) && canImport(AlarmKit)
        if #available(iOS 26.1, *) {
            do { _ = try await AlarmManager.shared.requestAuthorization() } catch {
                SystemAlarmScheduler.log.error("AlarmKit authorization failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
        return current
    }
}

#if os(iOS) && canImport(AlarmKit)
import AlarmKit
import SwiftUI

@available(iOS 26.1, *)
private struct AnuAlarmMetadata: AlarmMetadata {}

@available(iOS 26.1, *)
private enum AlarmKitBridge {
    enum Result { case scheduled, refused(String) }

    static func schedule(label: String, at date: Date) async -> Result {
        let log = SystemAlarmScheduler.log
        let manager = AlarmManager.shared
        var state = manager.authorizationState
        log.notice("AlarmKit authorization: \(String(describing: state), privacy: .public)")
        if state == .notDetermined {
            do {
                state = try await manager.requestAuthorization()
            } catch {
                log.error("AlarmKit authorization failed: \(error.localizedDescription, privacy: .public)")
                return .refused("Anu couldn't ask for the Alarms permission (\(error.localizedDescription)).")
            }
        }
        guard state == .authorized else {
            return .refused("Alarms is off for Anu. Turn it on in Settings → Anu → Alarms.")
        }

        // A fixed-date alarm for both kinds: a countdown presentation would
        // need a Live Activity widget, and a fixed alert rings the same way.
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: label))
        let attributes = AlarmAttributes<AnuAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert), metadata: nil, tintColor: .blue)
        let configuration = AlarmManager.AlarmConfiguration<AnuAlarmMetadata>.alarm(
            schedule: .fixed(date), attributes: attributes)
        let id = UUID()
        do {
            _ = try await manager.schedule(id: id, configuration: configuration)
        } catch {
            log.error("AlarmKit schedule failed: \(String(describing: error), privacy: .public)")
            return .refused("iOS refused the alarm (\(error.localizedDescription)).")
        }
        // Confirm iOS really holds it before saying it will ring.
        let held = ((try? manager.alarms) ?? []).contains { $0.id == id }
        log.notice("AlarmKit scheduled \(id, privacy: .public) for \(date, privacy: .public); listed: \(held, privacy: .public)")
        return held ? .scheduled : .refused("iOS took the alarm but doesn't list it.")
    }
}
#endif
