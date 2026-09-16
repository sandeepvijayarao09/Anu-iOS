import Foundation
import EventKit
import Combine

// MARK: - Shared EventKit access
//
// `CalendarTool` and `RemindersTool` each built a fresh `EKEventStore` per call.
// That does return current data — a new store reads through — but it has three
// costs: the authorization dance runs on every single call, nothing can react
// when the user edits an event in Calendar.app while Anu is open, and each
// store is a non-trivial allocation.
//
// One long-lived store fixes all three. EventKit only delivers
// `.EKEventStoreChanged` to a store that stays alive, and a store must be
// `reset()` after a change before its cached objects are trustworthy — which is
// exactly the bug a per-call store hides by never living long enough to cache.

// NOT `@MainActor`. It was, and that deadlocked: XCTest blocks the main thread
// to drive an `async` test, so a tool reaching for a main-actor store could
// never be served — the EventKit integration tests hung indefinitely instead of
// failing. Nothing here needs the main thread; only the `@Published` bump does,
// and that hops explicitly.
final class CalendarAccess: ObservableObject {
    static let shared = CalendarAccess()

    /// Bumped whenever EventKit reports an external change. Views and cached
    /// answers can observe this to know their data is stale.
    @Published private(set) var changeToken = 0

    let store = EKEventStore()
    private var observer: AnyCancellable?

    /// Access is requested once per launch per entity type, not per call.
    /// Guarded by a lock rather than actor isolation so callers on any thread
    /// (including a blocked-main-thread test) are served.
    private let lock = NSLock()
    private var eventsGranted: Bool?
    private var remindersGranted: Bool?

    private init() {
        observer = NotificationCenter.default
            .publisher(for: .EKEventStoreChanged, object: store)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Required after any external change: without it the store may
                // hand back objects that no longer match what's on disk.
                self.store.reset()
                self.changeToken += 1
            }
    }

    private func cachedGrant(_ keyPath: KeyPath<CalendarAccess, Bool?>) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return self[keyPath: keyPath]
    }

    /// Requests calendar access, caching the answer. Returns nil on success or
    /// a user-facing explanation on failure, so callers stay one-liners.
    func ensureEventAccess() async -> String? {
        if let cached = cachedGrant(\.eventsGranted) {
            return cached ? nil : Self.deniedMessage("Calendars")
        }
        do {
            let granted = try await store.requestFullAccessToEvents()
            lock.lock(); eventsGranted = granted; lock.unlock()
            return granted ? nil : Self.deniedMessage("Calendars")
        } catch {
            return "Couldn't access Calendar: \(error.localizedDescription)"
        }
    }

    func ensureReminderAccess() async -> String? {
        if let cached = cachedGrant(\.remindersGranted) {
            return cached ? nil : Self.deniedMessage("Reminders")
        }
        do {
            let granted = try await store.requestFullAccessToReminders()
            lock.lock(); remindersGranted = granted; lock.unlock()
            return granted ? nil : Self.deniedMessage("Reminders")
        } catch {
            return "Couldn't access Reminders: \(error.localizedDescription)"
        }
    }

    /// Events between two dates, earliest first.
    func events(from start: Date, to end: Date) -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    /// Events in the remainder of the calendar day containing `date`. "What's
    /// on my calendar today" means what's left of today, not since midnight.
    func eventsRemainingToday(from date: Date = Date()) -> [EKEvent] {
        let endOfDay = Calendar.current.startOfDay(for: date).addingTimeInterval(24 * 3600)
        guard endOfDay > date else { return [] }
        return events(from: date, to: endOfDay)
    }

    private static func deniedMessage(_ what: String) -> String {
        "\(what) access not granted. The user can enable it in Settings → Privacy → \(what)."
    }
}

// MARK: - Shared formatting

extension EKEvent {
    /// One-line summary used by both the tool output and the Siri snippet, so
    /// the two can't drift apart.
    var anuSummary: String {
        let time = isAllDay ? "all day" : AnuDate.time.string(from: startDate)
        return "\(title ?? "(untitled)") — \(time)"
    }
}
