import XCTest
@testable import Anu

/// The MIME writer and Gmail JSON reader (Android parity #10).
final class GmailMIMETests: XCTestCase {
    private func split(_ mime: String) -> (headers: [String], body: String) {
        let parts = mime.components(separatedBy: "\r\n\r\n")
        return (parts[0].components(separatedBy: "\r\n"), parts.dropFirst().joined(separator: "\r\n\r\n"))
    }

    func testPlainMessageHeadersAndBase64Body() throws {
        let mime = try GmailMIME.build(OutgoingEmail(
            to: ["maya@example.com", "raj@example.org"], cc: ["sam@example.net"],
            subject: "Lunch on Friday", body: "Hi Maya,\nnoon works. Café?"))
        let (headers, body) = split(mime)
        XCTAssertTrue(headers.contains("MIME-Version: 1.0"))
        XCTAssertTrue(headers.contains("To: maya@example.com, raj@example.org"))
        XCTAssertTrue(headers.contains("Cc: sam@example.net"))
        XCTAssertTrue(headers.contains("Subject: Lunch on Friday"), "printable ASCII stays as it is")
        XCTAssertTrue(headers.contains("Content-Type: text/plain; charset=\"UTF-8\""))
        XCTAssertTrue(headers.contains("Content-Transfer-Encoding: base64"))
        let decoded = Data(base64Encoded: body.replacingOccurrences(of: "\r\n", with: ""))
        XCTAssertEqual(decoded.map { String(decoding: $0, as: UTF8.self) }, "Hi Maya,\nnoon works. Café?")
    }

    func testLongBodyIsWrappedAt76() throws {
        let mime = try GmailMIME.build(OutgoingEmail(to: ["a@b.co"], subject: "x", body: String(repeating: "naïve ", count: 100)))
        let lines = split(mime).body.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertTrue(lines.allSatisfy { $0.count <= 76 })
    }

    func testNonASCIISubjectIsRFC2047EncodedWithoutSplittingCharacters() {
        let subject = "Réunion d’équipe — 東京オフィスの予定について 🎉🎉🎉 merci beaucoup"
        let encoded = GmailMIME.encodeHeaderWord(subject)
        let words = encoded.components(separatedBy: "\r\n ")
        XCTAssertGreaterThan(words.count, 1, "a long subject spans several encoded words")
        var decoded = ""
        for word in words {
            XCTAssertLessThanOrEqual(word.count, 75)
            XCTAssertTrue(word.hasPrefix("=?UTF-8?B?") && word.hasSuffix("?="), word)
            let payload = String(word.dropFirst(10).dropLast(2))
            let data = Data(base64Encoded: payload)!
            let text = String(data: data, encoding: .utf8)
            XCTAssertNotNil(text, "each word is valid UTF-8 on its own")
            decoded += text ?? ""
        }
        XCTAssertEqual(decoded, subject)
    }

    func testHeaderInjectionIsRefused() {
        XCTAssertThrowsError(try GmailMIME.build(OutgoingEmail(
            to: ["a@b.co"], subject: "Hi\r\nBcc: evil@x.com", body: "x"))) { error in
            XCTAssertEqual(error as? GmailMIMEError, .lineBreakInHeader("Subject"))
        }
        XCTAssertThrowsError(try GmailMIME.build(OutgoingEmail(to: ["a@b.co\nBcc: evil@x.com"], subject: "s", body: "x")))
        XCTAssertThrowsError(try GmailMIME.build(OutgoingEmail(to: ["not an address"], subject: "s", body: "x")))
        XCTAssertThrowsError(try GmailMIME.build(OutgoingEmail(to: ["a@b.co"], subject: "Hi\nBcc: evil@x.com", body: "x")))
        XCTAssertThrowsError(try GmailMIME.build(OutgoingEmail(to: [], subject: "s", body: "x"))) { error in
            XCTAssertEqual(error as? GmailMIMEError, .noRecipients)
        }
    }

    func testReplyHeaders() throws {
        let mime = try GmailMIME.build(OutgoingEmail(
            to: ["a@b.co"], subject: "Re: plan", body: "ok", inReplyTo: "<abc@mail>", references: "<abc@mail>"))
        let headers = split(mime).headers
        XCTAssertTrue(headers.contains("In-Reply-To: <abc@mail>"))
        XCTAssertTrue(headers.contains("References: <abc@mail>"))
    }

    func testBase64URLRoundTrip() {
        let data = Data((0...255).map { UInt8($0) })
        let encoded = GmailMIME.base64URL(data)
        XCTAssertFalse(encoded.contains("+") || encoded.contains("/") || encoded.contains("="))
        XCTAssertEqual(GmailMIME.decodeBase64URL(encoded), data)
        XCTAssertEqual(GmailMIME.base64URL("??>"), "Pz8-")
    }

    func testAddressSplitting() {
        XCTAssertEqual(GmailMIME.addresses(" a@b.co, c@d.org ;e@f.net,, "), ["a@b.co", "c@d.org", "e@f.net"])
        XCTAssertTrue(GmailMIME.isAddress("maya.chen+work@example.co.uk"))
        XCTAssertFalse(GmailMIME.isAddress("maya@"))
    }

    // MARK: Reading

    private func b64(_ text: String) -> String { GmailMIME.base64URL(text) }

    func testNestedPlainTextPartIsChosen() {
        let json: [String: Any] = [
            "id": "m1",
            "payload": [
                "mimeType": "multipart/alternative",
                "headers": [["name": "From", "value": "Maya <maya@example.com>"],
                            ["name": "Subject", "value": "Plan"],
                            ["name": "Message-ID", "value": "<id1@mail>"]],
                "parts": [
                    ["mimeType": "text/html", "body": ["data": b64("<p>html</p>")]],
                    ["mimeType": "multipart/related", "parts": [
                        ["mimeType": "text/plain", "body": ["data": b64("Plain café text")]],
                    ]],
                ],
            ],
        ]
        let message = GmailParsing.message(json)
        XCTAssertEqual(message.text, "Plain café text")
        XCTAssertEqual(message.from, "Maya <maya@example.com>")
        XCTAssertEqual(message.messageID, "<id1@mail>")
    }

    func testHTMLFallbackAndTruncation() {
        let html = "<html><style>p{}</style><p>Hello &amp; welcome&#8217;s</p><br>Line<script>x()</script></html>"
        let json: [String: Any] = ["id": "m", "payload": ["mimeType": "text/html", "body": ["data": b64(html)]]]
        let text = GmailParsing.message(json).text
        XCTAssertTrue(text.contains("Hello & welcome’s"), text)
        XCTAssertFalse(text.contains("x()") || text.contains("p{}"))

        let long: [String: Any] = ["id": "m", "payload": ["mimeType": "text/plain", "body": ["data": b64(String(repeating: "a", count: 5000))]]]
        let cut = GmailParsing.message(long).text
        XCTAssertTrue(cut.hasSuffix(" […]"))
        XCTAssertEqual(cut.count, GmailParsing.maxText + 4)
    }
}
