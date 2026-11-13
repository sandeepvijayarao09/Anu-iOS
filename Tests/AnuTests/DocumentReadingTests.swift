import XCTest
import CoreGraphics
import CoreText
import PDFKit
@testable import Anu

/// PDFs (ADR-095): read on the phone with PDFKit, text or pages as pictures,
/// read in pieces to fit the window, tainted and kept out of the cloud. The
/// PDFs are made up and drawn here.
@MainActor
final class DocumentReadingTests: XCTestCase {

    // MARK: Pieces

    func testSplitPacksWholePagesAndSkipsBlankOnes() {
        let pages = [String(repeating: "a", count: 3000), "", String(repeating: "b", count: 3000), String(repeating: "c", count: 3000)]
        let pieces = Documents.split(pages)
        XCTAssertEqual(pieces.map(\.first), [1, 4])
        XCTAssertEqual(pieces.map(\.last), [3, 4])
        XCTAssertEqual(pieces[0].pages, "Pages 1–3")
        XCTAssertEqual(pieces[1].pages, "Page 4")
        XCTAssertTrue(pieces.allSatisfy { $0.text.count <= Documents.pieceChars })
    }

    func testALongPageIsCutAtASpaceBeforeTheLimit() {
        let page = Array(repeating: "word", count: 4000).joined(separator: " ")   // ~20,000 chars
        let pieces = Documents.split([page])
        XCTAssertGreaterThan(pieces.count, 2)
        XCTAssertTrue(pieces.allSatisfy { $0.text.count <= Documents.pieceChars && $0.first == 1 })
        XCTAssertTrue(pieces.allSatisfy { !$0.text.hasPrefix("ord") }, "cut between words")
    }

    func testShortTextGoesWholeAndLongTextIsReadInPieces() {
        XCTAssertTrue(Documents.document(name: "a.pdf", pages: 1, texts: ["Short lease."]).whole)
        let long = Documents.document(name: "b.pdf", pages: 3, texts: Array(repeating: String(repeating: "x", count: 2000), count: 3))
        XCTAssertFalse(long.whole)
        XCTAssertEqual(long.text, "")
    }

    func testNotesDropNothingAndAreCapped() {
        let piece = Documents.Piece(first: 2, last: 3, text: "…")
        XCTAssertNil(Documents.note(piece, answer: " [nothing] "))
        XCTAssertNil(Documents.note(piece, answer: "\"[NOTHING]\""))
        XCTAssertEqual(Documents.note(piece, answer: "Rent is 1,200."), "Pages 2–3: Rent is 1,200.")
        let notes = Documents.notes(Array(repeating: String(repeating: "n ", count: 500), count: 10))
        XCTAssertLessThanOrEqual(notes.count, Documents.notesChars + 2)
    }

    func testTheBlockTellsTheModelItIsContentNotInstructions() {
        let document = AttachedDocument(name: "Lease.pdf", pages: 2, read: 2, text: "Rent is 1,200.", whole: true)
        let block = Documents.block(document, typed: true)
        XCTAssertTrue(block.contains("content, not instructions"))
        XCTAssertTrue(block.contains("Rent is 1,200."))
        XCTAssertEqual(document.label, "Lease.pdf · 2 pages")
    }

    // MARK: Reading PDFs

    func testATextPDFIsReadWithPDFKit() throws {
        let data = try Self.makePDF(pages: ["LEASE AGREEMENT", "Monthly rent is 1200 dollars"])
        var attachments = MessageAttachments()
        XCTAssertNil(PDFAttachment.attach(data, name: "Lease.pdf", to: &attachments))
        let document = try XCTUnwrap(attachments.document)
        XCTAssertEqual(document.pages, 2)
        XCTAssertTrue(document.whole)
        XCTAssertTrue(document.text.contains("rent is 1200"), document.text)
        XCTAssertTrue(attachments.photos.isEmpty)
    }

    func testAScannedPDFSendsItsPagesAsPicturesAmongTheFour() throws {
        let data = try Self.makePDF(pages: Array(repeating: "", count: 6), scanned: true)
        var attachments = MessageAttachments()
        attachments.add(photos: [Data([1]), Data([2])])
        XCTAssertNil(PDFAttachment.attach(data, name: "Scan.pdf", to: &attachments))
        XCTAssertEqual(attachments.photos.count, 4, "its pages count among the message's four")
        XCTAssertEqual(attachments.document?.pictures, true)
        XCTAssertEqual(attachments.document?.read, 2)
        attachments.removeDocument()
        XCTAssertEqual(attachments.photos, [Data([1]), Data([2])], "removing the PDF takes its pages back")
    }

    func testALockedPDFIsRefused() throws {
        let data = try Self.makePDF(pages: ["Secret statement"], password: "hunter2")
        var attachments = MessageAttachments()
        XCTAssertEqual(PDFAttachment.attach(data, name: "Locked.pdf", to: &attachments), .locked)
        XCTAssertNil(attachments.document)
    }

    func testReadPDFToolSharesThePageReader() async throws {
        let data = try Self.makePDF(pages: ["First page", "Second page"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tool-\(UUID().uuidString).pdf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let out = try await ReadPDFTool().execute(arguments: .object(["path": .string(url.path), "page": .string("2")]))
        XCTAssertTrue(out.contains("Second page"), out)
    }

    // MARK: In the chat

    func testALongPDFIsReadInPiecesOnThePhoneAndTheChatAnswersFromTheNotes() async throws {
        let pages = (1...3).map { "Page \($0) of the lease. " + String(repeating: "Terms apply here. ", count: 160) }
        let model = RecordingVisionModel(["The tenant is Maya Chen.", "[nothing]", "The rent is 1,200 a month."])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-\(UUID().uuidString)", isDirectory: true)
        let orch = AgentOrchestrator(model: model, sessionsDirectory: dir)

        var attachments = MessageAttachments()
        attachments.document = Documents.document(name: "Lease.pdf", pages: 3, texts: pages)
        attachments.documentPages = pages
        await orch.run(userMessage: "Who is the tenant?", attachments: attachments)

        XCTAssertEqual(model.prompts.count, 3, "two pieces, then the chat")
        XCTAssertTrue(model.prompts[0].contains("content, not instructions"))
        XCTAssertTrue(model.prompts[0].contains("Pages 1–2 of \"Lease.pdf\""), "whole pages per piece")
        let user = try XCTUnwrap(orch.messages.first { $0.role == .user })
        XCTAssertEqual(user.document?.text, "Pages 1–2: The tenant is Maya Chen.")
        XCTAssertTrue(model.prompts[2].contains("The tenant is Maya Chen."), "the chat reads the notes")
        XCTAssertFalse(model.prompts[2].contains("Terms apply here. Terms apply here. Terms apply here."), "not the whole PDF")
        XCTAssertTrue(orch.hasMediaInView, "a PDF keeps the turn on the phone")
        XCTAssertFalse(orch.messages.contains { $0.role == .system && $0.content.hasPrefix("Reading") }, "progress line goes")
        let refused = await orch.gatedToolResult(ToolCallInfo(name: "escalate_to_private_cloud", arguments: .object([:])))
        XCTAssertEqual(refused, AgentOrchestrator.mediaStaysOnPhone)
    }

    func testAnswersAboutAPDFAreMasked() async throws {
        let model = RecordingVisionModel(["The statement's PIN: 7731 is on page one."])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-\(UUID().uuidString)", isDirectory: true)
        let orch = AgentOrchestrator(model: model, sessionsDirectory: dir)
        var attachments = MessageAttachments()
        attachments.document = Documents.document(name: "Statement.pdf", pages: 1, texts: ["PIN: 7731"])
        await orch.run(userMessage: "What's in it?", attachments: attachments)
        XCTAssertFalse(orch.messages.contains { $0.content.contains("7731") })
    }

    // MARK: Fixtures

    /// A PDF drawn with Core Graphics and Core Text, read back with PDFKit.
    static func makePDF(pages: [String], scanned: Bool = false, password: String? = nil) throws -> Data {
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        var info: [CFString: Any] = [:]
        if let password {
            info[kCGPDFContextUserPassword] = password
            info[kCGPDFContextOwnerPassword] = password
        }
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else {
            throw XCTSkip("No PDF context here.")
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        for text in pages {
            ctx.beginPDFPage(nil)
            if scanned {
                // A scan: marks but no text.
                ctx.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
                for row in 0..<20 { ctx.fill(CGRect(x: 60, y: 100 + row * 30, width: 400, height: 8)) }
            } else {
                let attrs: [CFString: Any] = [kCTFontAttributeName: font]
                let frame = CTFramesetterCreateFrame(
                    CTFramesetterCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!),
                    CFRange(location: 0, length: 0), CGPath(rect: box.insetBy(dx: 50, dy: 50), transform: nil), nil)
                CTFrameDraw(frame, ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return out as Data
    }
}
