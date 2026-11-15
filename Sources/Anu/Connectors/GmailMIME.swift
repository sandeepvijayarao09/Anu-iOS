import Foundation

// Gmail message writing and reading (Android parity #10, `connector:gmail`
// Mime.kt). The model never supplies raw MIME: messages are built here from
// validated fields, and a header value holding CR or LF is refused, so text an
// email injected can't add headers or recipients.

/// A message Anu is about to draft or send, after validation.
struct OutgoingEmail: Equatable, Sendable {
    var to: [String]
    var cc: [String] = []
    var subject: String
    var body: String
    /// The parent's RFC 5322 Message-ID, for a reply.
    var inReplyTo: String? = nil
    var references: String? = nil
}

enum GmailMIMEError: Error, Equatable, LocalizedError {
    case noRecipients
    case notAnAddress(String)
    case lineBreakInHeader(String)

    var errorDescription: String? {
        switch self {
        case .noRecipients: return "An email needs at least one recipient."
        case .notAnAddress(let text): return "\"\(text)\" is not an email address."
        case .lineBreakInHeader(let name): return "A line break is not allowed in the \(name) header."
        }
    }
}

enum GmailMIME {
    // MARK: Addresses

    private static let addressPattern = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#)

    static func isAddress(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return addressPattern.firstMatch(in: text, range: range) != nil
    }

    /// "a@x.com, b@y.org; c@z.net" → three trimmed addresses (not validated).
    static func addresses(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: Writing

    /// An RFC 5322 message: plain text, UTF-8, base64 body, RFC 2047 subject.
    static func build(_ email: OutgoingEmail) throws -> String {
        guard !email.to.isEmpty else { throw GmailMIMEError.noRecipients }
        for address in email.to + email.cc where !isAddress(address) {
            throw GmailMIMEError.notAnAddress(address)
        }
        var headers: [(String, String)] = [("MIME-Version", "1.0"), ("To", email.to.joined(separator: ", "))]
        if !email.cc.isEmpty { headers.append(("Cc", email.cc.joined(separator: ", "))) }
        try checkOneLine(email.subject, header: "Subject")
        headers.append(("Subject", encodeHeaderWord(email.subject)))
        if let id = email.inReplyTo { headers.append(("In-Reply-To", id)) }
        if let refs = email.references { headers.append(("References", refs)) }
        headers.append(("Content-Type", "text/plain; charset=\"UTF-8\""))
        headers.append(("Content-Transfer-Encoding", "base64"))

        var out = ""
        for (name, value) in headers {
            // Encoded words are folded with CRLF + space on purpose; anything
            // else with a line break could start a new header.
            if name != "Subject" { try checkOneLine(value, header: name) }
            out += "\(name): \(value)\r\n"
        }
        out += "\r\n"
        out += wrappedBase64(Data(email.body.utf8))
        return out
    }

    /// RFC 2047 "B" encoding for a header value that isn't plain printable
    /// ASCII. Each encoded word stays within 75 characters and never splits a
    /// UTF-8 character; words are folded onto continuation lines.
    static func encodeHeaderWord(_ value: String) -> String {
        if value.unicodeScalars.allSatisfy({ (0x20...0x7e).contains($0.value) }) { return value }
        // 75 - len("=?UTF-8?B?") - len("?=") = 63 base64 characters → 45 bytes.
        let maxBytes = 45
        var words: [String] = []
        var chunk = Data()
        for character in value {
            let bytes = Data(String(character).utf8)
            if chunk.count + bytes.count > maxBytes, !chunk.isEmpty {
                words.append("=?UTF-8?B?" + chunk.base64EncodedString() + "?=")
                chunk = Data()
            }
            chunk.append(bytes)
        }
        if !chunk.isEmpty { words.append("=?UTF-8?B?" + chunk.base64EncodedString() + "?=") }
        return words.joined(separator: "\r\n ")
    }

    /// Base64 in lines of 76 characters, each ending CRLF (RFC 2045).
    static func wrappedBase64(_ data: Data) -> String {
        let encoded = data.base64EncodedString()
        guard !encoded.isEmpty else { return "" }
        var lines: [Substring] = []
        var start = encoded.startIndex
        while start < encoded.endIndex {
            let end = encoded.index(start, offsetBy: 76, limitedBy: encoded.endIndex) ?? encoded.endIndex
            lines.append(encoded[start..<end])
            start = end
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Gmail's `raw` field: base64url without padding (RFC 4648 §5).
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URL(_ text: String) -> String { base64URL(Data(text.utf8)) }

    /// Decodes base64url, with or without padding.
    static func decodeBase64URL(_ text: String) -> Data? {
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard = standard.filter { !$0.isWhitespace }
        let remainder = standard.count % 4
        if remainder > 0 { standard += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: standard)
    }

    private static func checkOneLine(_ value: String, header: String) throws {
        if hasLineBreak(value) { throw GmailMIMEError.lineBreakInHeader(header) }
    }

    /// Checked on scalars: Swift reads "\r\n" as one Character, so
    /// `contains("\r")` would miss it.
    static func hasLineBreak(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.newlines.contains($0) }
    }
}

// MARK: - Reading Gmail's JSON

struct GmailMessageSummary: Equatable, Sendable {
    let id: String
    let threadId: String
    let from: String
    let subject: String
    let date: String
    let snippet: String
}

struct GmailThreadMessage: Equatable, Sendable {
    let id: String
    let from: String
    let to: String
    let cc: String
    let subject: String
    let date: String
    /// The RFC 5322 Message-ID, used to thread replies.
    let messageID: String?
    let text: String
}

struct GmailThread: Equatable, Sendable {
    let id: String
    let messages: [GmailThreadMessage]
    var subject: String { messages.first?.subject ?? "" }
}

/// Reads Gmail's message JSON: headers, and the best text body from nested
/// MIME parts.
enum GmailParsing {
    /// Each message body is cut to this many characters (Android: 4,000).
    static let maxText = 4_000

    static func headers(_ message: [String: Any]) -> [String: String] {
        let payload = message["payload"] as? [String: Any]
        let list = payload?["headers"] as? [[String: Any]] ?? []
        var out: [String: String] = [:]
        for header in list {
            guard let name = header["name"] as? String, let value = header["value"] as? String else { continue }
            out[name.lowercased()] = value
        }
        return out
    }

    static func message(_ json: [String: Any]) -> GmailThreadMessage {
        let headers = headers(json)
        let payload = json["payload"] as? [String: Any]
        var text = payload.flatMap { part($0, mimeType: "text/plain") }
            ?? payload.flatMap { part($0, mimeType: "text/html") }.map(htmlToText)
            ?? ""
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maxText { text = String(text.prefix(maxText)) + " […]" }
        return GmailThreadMessage(
            id: json["id"] as? String ?? "",
            from: headers["from"] ?? "", to: headers["to"] ?? "", cc: headers["cc"] ?? "",
            subject: headers["subject"] ?? "", date: headers["date"] ?? "",
            messageID: headers["message-id"], text: text)
    }

    /// Depth-first search for the first part of `mimeType` with data.
    static func part(_ node: [String: Any], mimeType: String) -> String? {
        if (node["mimeType"] as? String)?.lowercased() == mimeType,
           let body = node["body"] as? [String: Any],
           let data = body["data"] as? String, !data.isEmpty,
           let decoded = GmailMIME.decodeBase64URL(data) {
            return String(decoding: decoded, as: UTF8.self)
        }
        for child in node["parts"] as? [[String: Any]] ?? [] {
            if let found = part(child, mimeType: mimeType) { return found }
        }
        return nil
    }

    static func htmlToText(_ html: String) -> String {
        var text = html
        let rules: [(String, String)] = [
            ("(?is)<(script|style)[^>]*>.*?</\\1>", " "),
            ("(?i)<br\\s*/?>|</p>|</div>|</li>|</tr>", "\n"),
            ("<[^>]+>", " "),
            ("[ \\t]+", " "),
            ("\\n\\s*\\n+", "\n\n"),
        ]
        for (pattern, replacement) in rules {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return decodeEntities(text)
    }

    static func decodeEntities(_ text: String) -> String {
        var out = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        // Numeric entities such as &#8217;.
        if let regex = try? NSRegularExpression(pattern: "&#(\\d{1,7});") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let code = Int(ns.substring(with: match.range(at: 1))) ?? 0
                result += Unicode.Scalar(code).map { String(Character($0)) } ?? ns.substring(with: match.range)
                last = match.range.location + match.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}
