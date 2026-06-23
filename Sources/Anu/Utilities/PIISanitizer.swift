import Foundation

/// Scrubs personally identifiable information from text before it leaves
/// the device (cloud escalation). On-device generation never needs this —
/// it exists so the privacy story survives the Gemini path.
enum PIISanitizer {

    struct Result: Equatable {
        let text: String
        let redactions: Int
    }

    static func sanitize(_ text: String) -> Result {
        var output = text
        var count = 0

        // Emails (before link detection so mailto doesn't double-count)
        count += replaceAll(
            pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            in: &output, with: "[EMAIL]"
        )

        // US SSN-style identifiers
        count += replaceAll(
            pattern: #"\b\d{3}-\d{2}-\d{4}\b"#,
            in: &output, with: "[ID]"
        )

        // Card-like long digit runs (13–19 digits, optional single separators
        // BETWEEN digits). Anchored with digit look-around rather than `\b`:
        // `\b` failed on 17+ pure-digit runs (no boundary between digits), and
        // a separator inside the repeat group ate the trailing space, fusing
        // "[NUMBER]" into the next word.
        count += replaceAll(
            pattern: #"(?<!\d)\d(?:[ -]?\d){12,18}(?!\d)"#,
            in: &output, with: "[NUMBER]"
        )

        // Phone numbers + street addresses via the system detector
        if let detector = try? NSDataDetector(types:
            NSTextCheckingResult.CheckingType.phoneNumber.rawValue |
            NSTextCheckingResult.CheckingType.address.rawValue
        ) {
            let matches = detector.matches(
                in: output, range: NSRange(output.startIndex..., in: output)
            )
            // Replace back-to-front so earlier ranges stay valid
            for match in matches.reversed() {
                guard let range = Range(match.range, in: output) else { continue }
                let placeholder = match.resultType == .phoneNumber ? "[PHONE]" : "[ADDRESS]"
                output.replaceSubrange(range, with: placeholder)
                count += 1
            }
        }

        return Result(text: output, redactions: count)
    }

    private static func replaceAll(pattern: String, in text: inout String, with placeholder: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let range = NSRange(text.startIndex..., in: text)
        let count = regex.numberOfMatches(in: text, range: range)
        if count > 0 {
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: placeholder)
        }
        return count
    }
}
