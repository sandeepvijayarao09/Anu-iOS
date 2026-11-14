import Foundation
import os

/// Alarms in the Clock app, through the "Anu Alarm" shortcut.
///
/// iOS lets only Clock add alarms to Clock; an AlarmKit alarm rings the same
/// but never shows in Clock's list. So once the user adds the shortcut
/// (Settings → Alarms), Anu runs it for an alarm: Shortcuts opens briefly,
/// Clock's own "Add Alarm" action sets it, and Shortcuts comes back to Anu
/// through `anu://clock-alarm/…` saying whether it worked. Clock alarms are a
/// time of day, so only an alarm within the next 24 hours goes to Clock.
enum ClockShortcut {
    static let name = "Anu Alarm"
    static let scheme = "anu"
    static let host = "clock-alarm"
    /// How long to wait for Shortcuts to come back before saying it's unconfirmed.
    static let timeout: Duration = .seconds(90)
    static let readyKey = "clockShortcutReady"
    static let log = Logger(subsystem: "com.anu.app", category: "Alarms")

    /// True once the user has added the shortcut (or it has worked once).
    static var isReady: Bool {
        get { UserDefaults.standard.bool(forKey: readyKey) }
        set { UserDefaults.standard.set(newValue, forKey: readyKey) }
    }

    /// Whether an alarm at `date` can be a Clock alarm: Clock rings at the
    /// next time its clock shows that time, so the date must be within a day.
    static func fits(_ date: Date, now: Date = Date()) -> Bool {
        let ahead = date.timeIntervalSince(now)
        return ahead > 0 && ahead < 24 * 60 * 60
    }

    /// The two lines the shortcut reads: the time, then the label.
    static func input(label: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let oneLine = label.replacingOccurrences(of: "\n", with: " ")
        return formatter.string(from: date) + "\n" + (oneLine.isEmpty ? "Alarm" : oneLine)
    }

    /// The Shortcuts URL that runs it and comes back to Anu with `id`.
    static func runURL(label: String, at date: Date, id: UUID) -> URL? {
        func back(_ path: String) -> String { "\(scheme)://\(host)/\(path)?id=\(id.uuidString)" }
        var components = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")
        components?.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: input(label: label, at: date)),
            URLQueryItem(name: "x-success", value: back("done")),
            URLQueryItem(name: "x-error", value: back("failed")),
            URLQueryItem(name: "x-cancel", value: back("cancelled")),
        ]
        // `+` and `&` inside values must be escaped for Shortcuts.
        let query = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = query
        return components?.url
    }

    enum Result: Equatable, Sendable {
        case done
        case failed(String)
        case cancelled
        case noAnswer
    }

    /// What a callback URL says, or nil when it isn't one of ours.
    static func parse(_ url: URL) -> (id: UUID, result: Result)? {
        guard url.scheme == scheme, url.host == host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let id = items.first(where: { $0.name == "id" })?.value.flatMap(UUID.init(uuidString:))
        else { return nil }
        switch url.lastPathComponent {
        case "done": return (id, .done)
        case "cancelled": return (id, .cancelled)
        case "failed":
            let message = items.first(where: { $0.name == "errorMessage" })?.value ?? "Shortcuts couldn't run it."
            return (id, .failed(message))
        default: return nil
        }
    }

    /// Handles a callback; true when the URL was one of ours.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard let (id, result) = parse(url) else { return false }
        log.notice("Clock shortcut came back: \(String(describing: result), privacy: .public)")
        if result == .done { isReady = true }
        Waiters.shared.resolve(id, result)
        return true
    }

    /// Runs the shortcut and waits for Shortcuts to say how it went.
    static func run(label: String, at date: Date) async -> Result {
        let id = UUID()
        guard let url = runURL(label: label, at: date, id: id) else { return .failed("Couldn't build the Shortcuts link.") }
        return await withCheckedContinuation { continuation in
            Waiters.shared.add(id, continuation)
            Task { @MainActor in
                guard await open(url) else {
                    Waiters.shared.resolve(id, .failed("Shortcuts didn't open."))
                    return
                }
                try? await Task.sleep(for: timeout)
                Waiters.shared.resolve(id, .noAnswer)
            }
        }
    }

    @MainActor
    private static func open(_ url: URL) async -> Bool {
        #if os(iOS)
        return await UIApplication.shared.open(url)
        #else
        return false
        #endif
    }

    /// The shortcut file to add, written where Share can hand it to Shortcuts.
    static func fileURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).shortcut")
        try signedFile.write(to: url, options: .atomic)
        return url
    }

    /// Continuations waiting on a callback, resumed exactly once.
    final class Waiters: @unchecked Sendable {
        static let shared = Waiters()
        private let lock = NSLock()
        private var waiting: [UUID: CheckedContinuation<Result, Never>] = [:]

        func add(_ id: UUID, _ continuation: CheckedContinuation<Result, Never>) {
            lock.lock(); waiting[id] = continuation; lock.unlock()
        }

        func resolve(_ id: UUID, _ result: Result) {
            lock.lock(); let continuation = waiting.removeValue(forKey: id); lock.unlock()
            continuation?.resume(returning: result)
        }
    }
}

#if os(iOS)
import UIKit
#endif
