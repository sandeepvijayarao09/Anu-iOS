import Foundation
import CoreGraphics
import ImageIO

// Photos and PDFs in a message (Android parity: ADR-075, ADR-094, ADR-095).
// They're read on the phone only: a turn with one in view stays on the device
// (never to Gemini or the private server), is tainted as content written by
// others (P4), and never reaches memory. They're kept with their message in the
// encrypted chat store (SecureFile), photos at most 1,024 pixels on a side.

/// What a user message keeps of its PDF: its name and size, and the text the
/// model reads. A short PDF's text is kept `whole`; a longer one's is the notes
/// its pieces gave for the question it came with. One read as `pictures` keeps
/// no text: its pages are the message's photos. The PDF itself is never kept.
struct AttachedDocument: Codable, Sendable, Equatable {
    let name: String
    let pages: Int
    /// How many of its pages were read, from the first.
    let read: Int
    var text: String
    var whole: Bool
    var pictures: Bool = false

    /// "Lease.pdf · 12 pages"
    var label: String { "\(name) · \(pages == 1 ? "1 page" : "\(pages) pages")" }
}

/// What the composer sends with a message: up to four photos, and one PDF.
struct MessageAttachments: Sendable {
    /// One message carries at most four pictures, the engine's `maxNumImages`.
    static let maxPhotos = 4
    static let tooMany = "Anu can look at up to 4 photos at once."

    var photos: [Data] = []
    var document: AttachedDocument?
    /// The PDF's page texts, for reading a long one in pieces (memory only).
    var documentPages: [String] = []
    /// The PDF's pages sent as pictures (a scan), among `photos`.
    var documentPictures: [Data] = []
    /// Codes found on masked screens, for masking answers (memory only).
    var knownCodes: [String] = []

    var isEmpty: Bool { photos.isEmpty && document == nil }
    var photosLeft: Int { max(0, Self.maxPhotos - photos.count) }

    /// Adds what fits of `more`; returns how many were left out.
    @discardableResult
    mutating func add(photos more: [Data]) -> Int {
        let fits = Array(more.prefix(photosLeft))
        photos += fits
        return more.count - fits.count
    }

    mutating func removePhoto(at index: Int) {
        guard photos.indices.contains(index) else { return }
        photos.remove(at: index)
    }

    /// Drops the PDF, and its pages too when they came as pictures.
    mutating func removeDocument() {
        let pages = documentPictures
        photos.removeAll { pages.contains($0) }
        document = nil
        documentPages = []
        documentPictures = []
    }
}

/// At most four pictures in the model's view (ADR-094): a live conversation
/// that already holds some starts afresh when the new message's would pass four.
enum PictureBudget {
    static let maxInView = MessageAttachments.maxPhotos

    static func fitsInView(held: Int, adding: Int) -> Bool { held + adding <= maxInView }
}

/// Readies a photo before anyone sees it: a screen-like picture has its
/// secrets blacked out (ScreenSecrets), and every photo is cut to 1,024 pixels
/// on its longer side and re-encoded, which also drops its metadata (place,
/// camera). Runs off the main actor (Vision).
enum PhotoPreparation {
    static let maxSide = 1024

    struct Prepared: Sendable {
        let data: Data
        let codes: [String]
        let masked: Int
    }

    /// `forceScreen`: the picture was handed over as a screenshot ("Ask About
    /// My Screen", a shared "Screenshot …"), so it's masked whatever it looks like.
    static func prepare(_ data: Data, forceScreen: Bool = false) -> Prepared? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let screen = forceScreen || ScreenSecrets.isScreenLike(data)
        // Screens are read larger so small text (a code in a banner) is found.
        guard var image = thumbnail(source, maxSide: screen ? 2048 : maxSide) else { return nil }
        var codes: [String] = []
        var masked = 0
        if screen {
            let result = ScreenSecrets.mask(image)
            image = result.image
            codes = result.codes
            masked = result.masked
        }
        if max(image.width, image.height) > maxSide, let small = resized(image, maxSide: maxSide) { image = small }
        guard let jpeg = jpeg(image) else { return nil }
        return Prepared(data: jpeg, codes: codes, masked: masked)
    }

    static func thumbnail(_ source: CGImageSource, maxSide: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func resized(_ image: CGImage, maxSide: Int) -> CGImage? {
        let scale = Double(maxSide) / Double(max(image.width, image.height))
        let width = Int(Double(image.width) * scale), height = Int(Double(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    static func jpeg(_ image: CGImage, quality: Double = 0.85) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func cgImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

extension AgentMessage {
    /// Every picture this message shows the model: its photos, or the single
    /// image of an older message.
    var pictures: [Data] {
        if let photos, !photos.isEmpty { return photos }
        return role == .user ? (imageData.map { [$0] } ?? []) : []
    }

    /// Whether this message holds media drawn from outside the chat: a photo
    /// or a PDF (MEDIA-1, MEDIA-2).
    var carriesMedia: Bool { role == .user && (!pictures.isEmpty || document != nil) }
}
