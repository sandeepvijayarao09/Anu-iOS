import Foundation

// "Hey Anu" (Android ADR-045, ADR-121), iOS form. Third-party iOS apps can't
// keep the microphone open in the background, so the wake phrase listens only
// while Anu is open and on screen. The background path is Siri: the "Ask Anu"
// App Shortcut ("Hey Siri, ask Anu …").

/// Finds "Hey Anu" or "Anu" at the start of what was heard, and returns what
/// follows, which is often the request itself: "Hey Anu, what's on my
/// calendar?". Android's matching rules:
/// - a bare name must be "Anu" itself, so "a new message" never wakes it;
/// - after "hey", common mishearings of the name count too.
enum WakePhrase {
    private static let bare = try? NSRegularExpression(
        pattern: "^\\s*(anu|anoo|annu)\\b[\\s,.!?:;-]*", options: [.caseInsensitive])
    private static let greeted = try? NSRegularExpression(
        pattern: "^\\s*(hey|hi|ok|okay)[\\s,]+(anu|anoo|annu|anew|ahnu|anou|a nu)\\b[\\s,.!?:;-]*",
        options: [.caseInsensitive])

    /// What followed the wake phrase, possibly empty, or nil if `heard`
    /// doesn't start with it.
    static func remainder(_ heard: String) -> String? {
        let range = NSRange(location: 0, length: (heard as NSString).length)
        guard let match = greeted?.firstMatch(in: heard, range: range)
                ?? bare?.firstMatch(in: heard, range: range) else { return nil }
        let rest = (heard as NSString).substring(from: match.range.location + match.range.length)
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Settings for the foreground wake phrase.
enum WakeSettings {
    /// UserDefaults key for the Settings switch. Off by default: an open
    /// microphone is something the user turns on.
    static let enabledKey = "hey_anu_enabled"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
}

/// One round of on-device recognition, as the wake loop sees it.
struct WakeRound: Equatable {
    /// The final words of the round, if any.
    var heard: String?
    var error: WakeRoundError?

    static func heard(_ text: String) -> WakeRound { WakeRound(heard: text, error: nil) }
    static let silence = WakeRound(heard: nil, error: WakeRoundError(reason: "silence", heardNothing: true))
    static func failed(_ reason: String, fatal: Bool = false) -> WakeRound {
        WakeRound(heard: nil, error: WakeRoundError(reason: reason, fatal: fatal))
    }
}

struct WakeRoundError: Equatable {
    var reason: String
    /// The quiet case: nothing was said.
    var heardNothing = false
    /// Waiting won't fix it: no on-device recognizer, no permission.
    var fatal = false
}

/// The "Hey Anu" loop on the recognizer, ported from Android's WakeListener.
/// It listens round after round and calls `onWake` with what followed the wake
/// phrase. Everything else it hears is dropped at once: never kept, logged or
/// sent.
/// - Silence just starts another round.
/// - Other errors back off, doubling each time; after `maxFailures` in a row it stops.
/// - A fatal error (no on-device recognizer, no permission) stops it at once.
/// - A recognizer that ends every round at once gets a pause, so it never spins.
struct WakeLoop {
    enum Stop: Equatable {
        /// `onWake` said Anu couldn't take the request.
        case cantOpen
        case failed(String)
        case cancelled
    }

    var maxFailures = 5
    var backoffMs = 2_000
    var quickRoundMs = 1_000
    var maxQuickRounds = 3
    var pauseMs = 5_000
    var roundGapMs = 250

    /// One recognition round.
    let listen: () async -> WakeRound
    /// Monotonic milliseconds.
    let clock: () -> Int
    /// Waits, in milliseconds. Throws when cancelled.
    let sleep: (Int) async throws -> Void

    /// `onWake` gets the request after the wake phrase, or nil for just
    /// "Hey Anu", and says whether Anu took it.
    func run(onWake: (String?) async -> Bool) async -> Stop {
        var failures = 0
        var quickRounds = 0
        do {
            while true {
                if Task.isCancelled { return .cancelled }
                let startedAt = clock()
                let round = await listen()
                if Task.isCancelled { return .cancelled }
                if let text = round.heard {
                    failures = 0
                    if let request = WakePhrase.remainder(text) {
                        let took = await onWake(request.isEmpty ? nil : request)
                        if !took { return .cantOpen }
                    }
                } else if let error = round.error, !error.heardNothing {
                    if error.fatal { return .failed(error.reason) }
                    failures += 1
                    if failures >= maxFailures { return .failed(error.reason) }
                    try await sleep(backoffMs << (failures - 1))
                } else {
                    failures = 0
                }
                if clock() - startedAt < quickRoundMs {
                    quickRounds += 1
                    if quickRounds >= maxQuickRounds {
                        try await sleep(pauseMs)
                        quickRounds = 0
                    }
                } else {
                    quickRounds = 0
                }
                try await sleep(roundGapMs)
            }
        } catch {
            return .cancelled
        }
    }
}
