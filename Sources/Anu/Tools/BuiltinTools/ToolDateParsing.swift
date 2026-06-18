import Foundation

/// Lenient date-string parsing shared by the EventKit-backed tools. Accepts
/// ISO-8601 plus a few common human formats. Returns nil when nothing matches.
enum ToolDateParsing {
    static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: trimmed) { return d }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss",
                    "yyyy-MM-dd", "MM/dd/yyyy HH:mm", "MM/dd/yyyy", "MMMM d, yyyy h:mm a"] {
            f.dateFormat = fmt
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
    }
}
