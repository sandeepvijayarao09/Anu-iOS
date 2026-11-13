import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Screens never show a model their secrets (Android parity: ADR-082/083). A
/// screenshot can hold a one-time code, a card number or a password the user
/// didn't mean to hand over, so before any model sees a screen-like picture,
/// Vision reads its text on the phone and the secrets are blacked out in the
/// pixels. The codes found are kept in memory with the turn (never saved) so
/// an answer is masked wherever they come back.
enum ScreenSecrets {
    struct Result {
        let image: CGImage
        /// How many secrets were blacked out.
        let masked: Int
        /// The code-shaped secrets found, for masking answers (memory only).
        let codes: [String]
    }

    /// Long side / short side of the screens Anu runs on and people screenshot:
    /// phones (19.5:9, 16:9), iPads (4:3, 10:7, 23:16) and Macs (16:10).
    private static let screenRatios: [Double] = [2.1667, 2.1641, 2.1653, 1.7778, 1.3333, 1.4318, 1.4389, 1.6]

    /// Whether the picture in `data` looks like a screen rather than a photo:
    /// iOS marks screenshots as such; otherwise a picture with no camera
    /// metadata whose shape is a screen's.
    static func isScreenLike(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return false }
        return isScreenLike(width: width, height: height, properties: props)
    }

    static func isScreenLike(width: Int, height: Int, properties: [CFString: Any]) -> Bool {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if let comment = exif[kCGImagePropertyExifUserComment] as? String,
           comment.localizedCaseInsensitiveContains("screenshot") { return true }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let fromCamera = exif[kCGImagePropertyExifExposureTime] != nil
            || exif[kCGImagePropertyExifFNumber] != nil
            || tiff[kCGImagePropertyTIFFMake] != nil
        guard !fromCamera, width > 0, height > 0 else { return false }
        let ratio = Double(max(width, height)) / Double(min(width, height))
        return screenRatios.contains { abs($0 - ratio) / $0 < 0.015 }
    }

    /// Reads `image`'s text with Vision and blacks out every secret in it.
    /// Returns the image unchanged when nothing is found.
    static func mask(_ image: CGImage) -> Result {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Correction "fixes" digits into words; codes must be read as written.
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return Result(image: image, masked: 0, codes: []) }
        let candidates = (request.results ?? []).compactMap { $0.topCandidates(1).first }
        let screenText = candidates.map(\.string).joined(separator: "\n")

        var boxes: [CGRect] = []
        var codes: [String] = []
        for candidate in candidates {
            let line = candidate.string
            for range in TextSecrets.ranges(in: line, screenText: screenText) {
                let secret = String(line[range])
                if secret.filter(\.isNumber).count >= 4 { codes.append(secret) }
                // The secret's own box where Vision gives one, else its line's.
                let own = (try? candidate.boundingBox(for: range))?.boundingBox
                let lineBox = (try? candidate.boundingBox(for: line.startIndex..<line.endIndex))?.boundingBox
                if let box = own ?? lineBox { boxes.append(box) }
            }
        }
        guard !boxes.isEmpty else { return Result(image: image, masked: 0, codes: []) }
        guard let masked = blackOut(boxes, in: image) else { return Result(image: image, masked: 0, codes: codes) }
        return Result(image: masked, masked: boxes.count, codes: codes)
    }

    /// Draws `image` with each normalized box (Vision's lower-left origin, the
    /// same as Core Graphics') filled black, padded a little.
    private static func blackOut(_ boxes: [CGRect], in image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for box in boxes {
            let rect = CGRect(x: box.minX * CGFloat(width), y: box.minY * CGFloat(height),
                              width: box.width * CGFloat(width), height: box.height * CGFloat(height))
            ctx.fill(rect.insetBy(dx: -4, dy: -4))
        }
        return ctx.makeImage()
    }
}
