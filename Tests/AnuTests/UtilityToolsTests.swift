import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import Anu

/// Real round-trips (no permission needed): clipboard set→get, a Documents file
/// write→read→list, and the keep-awake toggle.
final class UtilityToolsTests: XCTestCase {

    func testClipboardSetThenGet() async throws {
        let marker = "anu-clip-\(UUID().uuidString.prefix(6))"
        _ = try await ClipboardTool().execute(arguments: .object([
            "action": .string("set"), "text": .string(marker),
        ]))
        let out = try await ClipboardTool().execute(arguments: .object(["action": .string("get")]))
        XCTAssertTrue(out.contains(marker), "clipboard get should return what was set — got: \(out)")
    }

    func testFilesWriteReadList() async throws {
        let name = "anu-test-\(UUID().uuidString.prefix(6)).txt"
        defer { try? FileManager.default.removeItem(at: FilesTool.safeURL(for: name)!) }

        let body = "hello from Anu\nline two"
        let wrote = try await FilesTool().execute(arguments: .object([
            "action": .string("write"), "name": .string(name), "content": .string(body),
        ]))
        XCTAssertTrue(wrote.contains("Saved"), wrote)

        let read = try await FilesTool().execute(arguments: .object([
            "action": .string("read"), "name": .string(name),
        ]))
        XCTAssertEqual(read, body)

        let list = try await FilesTool().execute(arguments: .object(["action": .string("list")]))
        XCTAssertTrue(list.contains(name), "list should include the written file — got: \(list)")
    }

    func testFilesConfinesToDocuments() {
        // A traversal-y or nested name is reduced to a safe leaf INSIDE Documents —
        // it can't escape the sandbox.
        let traversal = FilesTool.safeURL(for: "../secrets")
        XCTAssertEqual(traversal?.lastPathComponent, "secrets")
        XCTAssertEqual(traversal?.deletingLastPathComponent().lastPathComponent, "Documents")
        XCTAssertEqual(FilesTool.safeURL(for: "a/b/notes.txt")?.lastPathComponent, "notes.txt")
        // Bare "." / ".." have no usable leaf → rejected.
        XCTAssertNil(FilesTool.safeURL(for: ".."))
        XCTAssertNil(FilesTool.safeURL(for: "."))
    }

    #if canImport(UIKit)
    @MainActor
    func testKeepAwakeToggles() async throws {
        _ = try await KeepAwakeTool().execute(arguments: .object(["action": .string("on")]))
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        _ = try await KeepAwakeTool().execute(arguments: .object(["action": .string("off")]))
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
    }

    // Generate a real PDF with known text, then extract it back through the tool.
    func testReadPDFExtractsText() async throws {
        let marker = "PDF ANU 2026"
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            ctx.beginPage()
            (marker as NSString).draw(at: CGPoint(x: 20, y: 20),
                                      withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anu-\(UUID().uuidString.prefix(6)).pdf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let out = try await ReadPDFTool().execute(arguments: .object(["path": .string(url.path)]))
        XCTAssertTrue(out.contains("ANU"), "PDF text extraction should recover the text — got: \(out)")
    }
    #endif
}
