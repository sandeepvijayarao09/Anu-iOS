import XCTest
import CoreGraphics
import CoreText
import ImageIO
@testable import Anu

/// REAL on-device OCR test: renders known text into an image with CoreText, then
/// runs the actual Vision recognizer over it — no mock, no bundled fixture.
final class ReadTextToolTests: XCTestCase {

    func testRecognizesRenderedText() throws {
        let image = try renderText("HELLO ANU")
        let out = TextRecognizer.recognizeText(in: image).uppercased()
        XCTAssertTrue(out.contains("HELLO"), "Vision OCR should read 'HELLO' — got: \(out)")
        XCTAssertTrue(out.contains("ANU"), "Vision OCR should read 'ANU' — got: \(out)")
    }

    func testToolReadsTextFromAFile() async throws {
        let image = try renderText("INVOICE")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-\(UUID().uuidString).png")
        try writePNG(image, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let out = try await ReadTextTool().execute(arguments: .object(["path": .string(url.path)]))
        XCTAssertTrue(out.uppercased().contains("INVOICE"), "tool OCR got: \(out)")
    }

    // MARK: - Fixture rendering (pure CoreText/CoreGraphics — cross-platform)

    private func renderText(_ text: String) throws -> CGImage {
        let width = 640, height = 200
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw XCTSkip("Couldn't create a bitmap context here.") }

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica" as CFString, 72, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let attr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 40, y: 70)
        CTLineDraw(line, ctx)

        guard let image = ctx.makeImage() else { throw XCTSkip("Couldn't render the fixture image.") }
        return image
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw XCTSkip("Couldn't create a PNG destination here.")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("Couldn't write the PNG.") }
    }
}
