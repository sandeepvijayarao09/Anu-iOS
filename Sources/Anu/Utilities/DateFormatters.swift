import Foundation

// MARK: - Shared date formatters
//
// `DateFormatter` was being constructed in twelve places across seven files,
// each re-deriving the same two or three styles. That drifts — one tool says
// "Sep 15, 2026 at 2:00 PM" and the next says "9/15/26" for the same event —
// and each instance is a genuinely expensive allocation.
//
// These are the only formats Anu actually uses. Kept as `static let` so each is
// built once per process, which is also the documented way to make
// `DateFormatter` cheap.

enum AnuDate {

    /// "2:00 PM" — a time within a day already established by context.
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// "Sep 15, 2026 at 2:00 PM" — the default for anything the user reads in
    /// a tool result or a list row.
    static let dateAndTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// "Sep 15, 2026" — a date where the time is irrelevant.
    static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// "Tuesday, September 15, 2026 at 2:00 PM" — spoken answers, where a
    /// listener needs the weekday to place the date without looking.
    static let spoken: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()
}
