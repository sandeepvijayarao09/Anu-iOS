import XCTest
import Photos
import CoreGraphics
import CoreText
import ImageIO
@testable import Anu

/// REAL PhotoKit integration: adds a rendered image to the simulator's photo
/// library through the actual tool and confirms the library count grows.
/// Permission-gated (skips without a Photos grant). Grant with:
///   xcrun simctl privacy booted grant photos-add com.anu.app
///   xcrun simctl privacy booted grant photos     com.anu.app
final class PhotosIntegrationTests: XCTestCase {

    func testCountThenSaveIncreasesLibrary() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        try XCTSkipUnless(status == .authorized || status == .limited,
                          "Photos access unavailable — skipping real PhotoKit test.")

        let countOut = try await PhotoLibraryTool().execute(arguments: .object(["action": .string("count")]))
        XCTAssertTrue(countOut.lowercased().contains("photo"), "count message — got: \(countOut)")

        let before = PHAsset.fetchAssets(with: .image, options: nil).count
        let url = try renderPNG()
        defer { try? FileManager.default.removeItem(at: url) }

        let saveOut = try await PhotoLibraryTool().execute(arguments: .object([
            "action": .string("save"), "path": .string(url.path),
        ]))
        XCTAssertTrue(saveOut.contains("Saved"), "save should succeed — got: \(saveOut)")

        let after = PHAsset.fetchAssets(with: .image, options: nil).count
        XCTAssertGreaterThanOrEqual(after, before + 1, "saving should add a photo to the library")
    }

    private func renderPNG() throws -> URL {
        guard let ctx = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw XCTSkip("no bitmap context") }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = ctx.makeImage() else { throw XCTSkip("no image") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anu-photo-\(UUID().uuidString.prefix(6)).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw XCTSkip("no PNG destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("PNG write failed") }
        return url
    }
}
