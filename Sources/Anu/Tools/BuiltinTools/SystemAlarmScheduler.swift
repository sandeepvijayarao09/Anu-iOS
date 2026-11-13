import Foundation

/// The timer and alarm scheduler the app uses (Android parity #16, ADR-076).
///
/// On an iPhone with AlarmKit (iOS 26.1 and later) and the user's permission,
/// a timer or alarm is a real system alarm: it rings through silent mode and
/// Focus and shows on the Lock Screen, like one from the Clock app. Anywhere
/// else, or when the user says no to AlarmKit, it falls back to a local
/// notification, which is what Anu did before.
struct SystemAlarmScheduler: TimerScheduling {
    let fallback: any TimerScheduling

    init(fallback: any TimerScheduling) {
        self.fallback = fallback
    }

    func schedule(label: String, at date: Date) async -> Bool {
        await schedule(label: label, at: date, kind: .alarm)
    }

    func schedule(label: String, at date: Date, kind: TimerKind) async -> Bool {
        #if os(iOS) && canImport(AlarmKit)
        if #available(iOS 26.1, *) {
            if let scheduled = await AlarmKitBridge.schedule(label: label, at: date) {
                return scheduled
            }
        }
        #endif
        return await fallback.schedule(label: label, at: date, kind: kind)
    }
}

#if os(iOS) && canImport(AlarmKit)
import AlarmKit
import SwiftUI

@available(iOS 26.1, *)
private struct AnuAlarmMetadata: AlarmMetadata {}

@available(iOS 26.1, *)
private enum AlarmKitBridge {
    /// True or false when AlarmKit took the request; nil when it isn't
    /// authorized, so the caller falls back to a notification.
    static func schedule(label: String, at date: Date) async -> Bool? {
        let manager = AlarmManager.shared
        var state = manager.authorizationState
        if state == .notDetermined {
            state = (try? await manager.requestAuthorization()) ?? .denied
        }
        guard state == .authorized else { return nil }

        // A fixed-date alarm for both kinds: a countdown presentation would
        // need a Live Activity widget, and a fixed alert rings the same way.
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: label))
        let attributes = AlarmAttributes<AnuAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert), metadata: nil, tintColor: .accentColor)
        let configuration = AlarmManager.AlarmConfiguration<AnuAlarmMetadata>.alarm(
            schedule: .fixed(date), attributes: attributes)
        do {
            _ = try await manager.schedule(id: UUID(), configuration: configuration)
            return true
        } catch {
            return false
        }
    }
}
#endif
