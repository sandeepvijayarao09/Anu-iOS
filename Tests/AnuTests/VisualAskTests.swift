import CoreVideo
import UIKit
import XCTest
@testable import Anu

/// "Ask Anu about this" from Visual Intelligence: the picture waits only
/// until it's asked about, and becomes a JPEG small enough to send.
final class VisualAskTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("visual-ask-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testAPictureIsTakenOnce() throws {
        let id = try VisualAsk.stash(Data("jpeg".utf8), directory: dir)
        XCTAssertEqual(VisualAsk.take(id, directory: dir), Data("jpeg".utf8))
        XCTAssertNil(VisualAsk.take(id, directory: dir), "deleted when taken")
    }

    func testAnOldPictureIsDeleted() throws {
        let then = Date()
        let id = try VisualAsk.stash(Data("old".utf8), directory: dir, now: then)
        let url = dir.appendingPathComponent(id).appendingPathExtension("jpg")
        try FileManager.default.setAttributes([.modificationDate: then.addingTimeInterval(-VisualAsk.keepFor - 1)],
                                              ofItemAtPath: url.path)
        XCTAssertNil(VisualAsk.take(id, directory: dir, now: then))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAnIdIsNeverAPath() throws {
        let outside = dir.deletingLastPathComponent().appendingPathComponent("secret-\(UUID().uuidString).jpg")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertNil(VisualAsk.take("../\(outside.deletingPathExtension().lastPathComponent)", directory: dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testABigPictureIsScaledDownToAJPEG() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4_096, 1_024, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let jpeg = try XCTUnwrap(VisualAsk.jpeg(from: XCTUnwrap(buffer)))
        let image = try XCTUnwrap(UIImage(data: jpeg))
        XCTAssertEqual(jpeg.prefix(2), Data([0xFF, 0xD8]), "a JPEG")
        XCTAssertEqual(max(image.size.width * image.scale, image.size.height * image.scale), VisualAsk.maxSide, accuracy: 1)
    }
}
