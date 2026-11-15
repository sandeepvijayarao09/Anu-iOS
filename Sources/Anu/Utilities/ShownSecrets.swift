import Foundation

// Secrets in pictures (Android parity: SECRETS-1, ADR-082, invariant I1's photo
// exception). A photo or PDF the user attaches may show the on-device model a
// one-time code, a card number or a password: it's theirs to show, and it never
// leaves the phone or reaches memory. What Anu says about it is guarded: the
// answer streams only until the first number that could be a code, is then held
// until it's complete, masked, and shown whole. The saved chat keeps only the
// masked answer. Over-masking an answer is fine; repeating a secret is not.

/// One-time verification codes act as credentials (S3).
enum OneTimeCodes {
    static let mask = "••••••"

    private static let verification = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"\b(code|otp|one[- ]time|verification|verify|passcode|pin|2fa|two[- ]factor|security code|log ?in|sign[- ]?in|authenticat\w*)\b"#,
        options: [.caseInsensitive])
    static let digits = try! NSRegularExpression(pattern: #"(?<!\d)(\d{3}[ -]\d{3}|\d{4,8})(?!\d)"#) // swiftlint:disable:this force_try

    /// Whether `text` speaks of a code, OTP, PIN or sign-in.
    static func speaksOfCode(_ text: String) -> Bool { verification.matches(text) }

    /// Whether `text` holds something shaped like a code: 4 to 8 digits, or "123 456".
    static func containsCode(_ text: String) -> Bool { digits.matches(text) }

    /// The code-shaped runs in `text`, as written.
    static func codes(in text: String) -> [String] { digits.strings(in: text) }

    /// `text` with its code-shaped runs masked when it, or `context` (the
    /// user's question), speaks of a code: "What's the code?" "It's 482913."
    static func mask(_ text: String, context: String = "") -> String {
        guard speaksOfCode(context + "\n" + text), containsCode(text) else { return text }
        return digits.replace(in: text, with: mask)
    }
}

/// Payment card numbers: 13 to 19 digits, spaces or dashes allowed, that pass
/// the Luhn check (so a phone number or an order number is left alone).
enum CardNumbers {
    private static let candidate = try! NSRegularExpression(pattern: #"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#) // swiftlint:disable:this force_try

    static func ranges(in text: String) -> [Range<String.Index>] {
        candidate.ranges(in: text).filter { isCard(String(text[$0])) }
    }

    static func isCard(_ raw: String) -> Bool {
        let digits = raw.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 { let doubled = d * 2; sum += doubled > 9 ? doubled - 9 : doubled } else { sum += d }
        }
        return sum % 10 == 0
    }

    static func mask(_ text: String) -> String {
        var out = text
        for range in ranges(in: text).reversed() { out.replaceSubrange(range, with: OneTimeCodes.mask) }
        return out
    }
}

/// Strings that look like a password on their own: 8 or more characters with
/// upper and lower case letters, a digit and a symbol, and none of the marks
/// that make it an address or a file name.
enum PasswordLike {
    private static let symbols = Set("!#$%^&*_+=?~-()[]{}<>|;:,")

    static func isPasswordLike(_ token: String) -> Bool {
        guard (8...64).contains(token.count),
              !token.contains("@"), !token.contains("/"), !token.contains(".") else { return false }
        return token.contains(where: \.isUppercase) && token.contains(where: \.isLowercase)
            && token.contains(where: \.isNumber) && token.contains(where: { symbols.contains($0) })
    }
}

/// Masks the secrets a picture or PDF could have shown in an answer about it.
enum ShownSecrets {
    /// The value after "password", "passcode", "PIN" or "pwd".
    private static let labelled = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"\b(password|passcode|pin|pwd)\b(\s*(?:is|:|=)\s*)(\S+?)(?=[.,;!?]?(?:\s|$))"#,
        options: [.caseInsensitive])

    /// `answer` with its secrets masked. `asked` is what the user wrote, which
    /// can make it an answer about a code. `known` are codes found in the
    /// picture itself (a masked screen's), masked wherever they appear however
    /// the answer puts them ("482913", "482 913", "482-913").
    static func mask(_ answer: String, asked: String, known: [String] = []) -> String {
        var out = answer
        for code in known {
            let digits = code.filter(\.isNumber)
            guard digits.count >= 4 else { continue }
            let pattern = digits.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[ -]?")
            if let regex = try? NSRegularExpression(pattern: pattern) {
                out = regex.replace(in: out, with: OneTimeCodes.mask)
            }
        }
        out = CardNumbers.mask(out)
        out = OneTimeCodes.mask(out, context: asked)
        let range = NSRange(out.startIndex..., in: out)
        return labelled.stringByReplacingMatches(in: out, range: range, withTemplate: "$1$2" + OneTimeCodes.mask)
    }
}

/// Holds an answer's stream at the first possible code (three digits or more)
/// so a code is never shown and taken back; `finish` masks the whole answer.
/// One per answer; used on the main actor by the chat turn.
final class AnswerShield {
    let asked: String
    let known: [String]
    private var raw: [Character] = []
    private var shown = 0
    private var holding = false

    init(asked: String, known: [String] = []) {
        self.asked = asked
        self.known = known
    }

    /// Whether the rest of the answer is held until it completes.
    var isHolding: Bool { holding }

    /// The part of the stream that's safe to show after `delta`, possibly "".
    func next(_ delta: String) -> String {
        raw.append(contentsOf: delta)
        if holding { return "" }
        let stop = codeStart(from: shown)
        let until = stop?.at ?? raw.count
        let out = String(raw[shown..<until])
        shown = until
        if stop?.hold == true { holding = true }
        return out
    }

    /// The whole answer, masked: what's shown and saved.
    func finish(_ answer: String) -> String {
        ShownSecrets.mask(answer, asked: asked, known: known)
    }

    /// Where the first possible code starts at or after `from`, and whether it
    /// is long enough to hold the rest for good. A shorter run of digits at the
    /// very end may still grow, so it waits too.
    private func codeStart(from: Int) -> (at: Int, hold: Bool)? {
        var i = from
        while i < raw.count {
            guard raw[i].isNumber, i == 0 || !raw[i - 1].isNumber else { i += 1; continue }
            var digits = 0
            var j = i
            while j < raw.count,
                  raw[j].isNumber || ((raw[j] == " " || raw[j] == "-") && j + 1 < raw.count && raw[j + 1].isNumber) {
                if raw[j].isNumber { digits += 1 }
                j += 1
            }
            if digits >= 3 { return (i, true) }
            if j == raw.count || (j == raw.count - 1 && (raw[j] == " " || raw[j] == "-")) { return (i, false) }
            i = j
        }
        return nil
    }
}

/// Where the secrets sit in one line of a screen's text, for masking them in
/// the picture itself before any model sees it (ScreenSecrets). `screenText`
/// is all the screen's text: a code is masked when the screen speaks of one.
enum TextSecrets {
    private static let labelledValue = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"\b(?:password|passcode|pin|pwd)\b\s*(?:is|:|=)\s*(\S+)"#, options: [.caseInsensitive])
    private static let token = try! NSRegularExpression(pattern: #"\S+"#) // swiftlint:disable:this force_try

    static func ranges(in line: String, screenText: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = CardNumbers.ranges(in: line)
        if OneTimeCodes.speaksOfCode(screenText) {
            found += OneTimeCodes.digits.ranges(in: line)
        }
        let whole = NSRange(line.startIndex..., in: line)
        for match in labelledValue.matches(in: line, range: whole) {
            if let r = Range(match.range(at: 1), in: line) { found.append(r) }
        }
        found += token.ranges(in: line).filter { PasswordLike.isPasswordLike(String(line[$0])) }
        return found
    }
}

// MARK: - Regex helpers

fileprivate extension NSRegularExpression {
    func matches(_ text: String) -> Bool {
        firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    func ranges(in text: String) -> [Range<String.Index>] {
        matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    func strings(in text: String) -> [String] {
        ranges(in: text).map { String(text[$0]) }
    }

    func replace(in text: String, with template: String) -> String {
        stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                 withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }
}
