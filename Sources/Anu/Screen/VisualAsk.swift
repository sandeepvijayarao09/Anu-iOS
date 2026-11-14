import CoreImage
import CoreVideo
import Foundation

// "Ask Anu about this" in Visual Intelligence (the closest iOS form of
// Android ADR-083's screen questions). When the user circles something with
// the camera control or on a screenshot, iOS asks apps for results; Anu offers
// one, and tapping it opens Anu with that picture in the composer, readied
// like any screen (`ScreenQuestion.handOver`: text read and secrets blacked
// out on this phone). The picture waits in Anu's own protected storage only
// between the search and the tap, and is deleted when taken or after a while.

enum VisualAsk {
    static let question = "What is this?"
    /// A picture not asked about within this long is deleted.
    static let keepFor: TimeInterval = 10 * 60
    /// The longest side kept. Enough to read text; small enough to send fast.
    static let maxSide: CGFloat = 2_048

    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("visual-ask", isDirectory: true)
    }

    /// Keeps `jpeg` until it is asked about, and returns its id.
    static func stash(_ jpeg: Data, directory: URL = directory, now: Date = Date()) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        prune(directory: directory, now: now)
        let id = UUID().uuidString
        try jpeg.write(to: file(id, in: directory), options: [.atomic, .completeFileProtection])
        return id
    }

    /// The picture for `id`, deleted as it is read. Nil for an unknown or
    /// malformed id, or one that expired.
    static func take(_ id: String, directory: URL = directory, now: Date = Date()) -> Data? {
        guard UUID(uuidString: id) != nil else { return nil }   // never a path
        prune(directory: directory, now: now)
        let url = file(id, in: directory)
        defer { try? FileManager.default.removeItem(at: url) }
        return try? Data(contentsOf: url)
    }

    /// Deletes pictures older than `keepFor`.
    static func prune(directory: URL = directory, now: Date = Date()) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for url in names {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(date) > keepFor { try? fm.removeItem(at: url) }
        }
    }

    /// A JPEG of `pixels`, scaled down so its longest side is at most `maxSide`.
    static func jpeg(from pixels: CVPixelBuffer) -> Data? {
        var image = CIImage(cvPixelBuffer: pixels)
        let side = max(image.extent.width, image.extent.height)
        guard side > 0 else { return nil }
        if side > maxSide {
            let scale = maxSide / side
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return CIContext().jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85])
    }

    private static func file(_ id: String, in directory: URL) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension("jpg")
    }
}

#if os(iOS) && canImport(VisualIntelligence) && compiler(>=6.4)  // iOS 27 SDK APIs (Xcode 27)
import AppIntents
import VisualIntelligence

/// The one result Anu shows in Visual Intelligence.
@available(iOS 26.0, *)
struct VisualAskEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Ask Anu"
    static let defaultQuery = VisualAskEntityQuery()

    /// The stashed picture's id.
    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Ask Anu about this",
                              subtitle: "Answered on this iPhone",
                              image: .init(systemName: "sparkles"))
    }
}

@available(iOS 26.0, *)
struct VisualAskEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [VisualAskEntity] {
        identifiers.map(VisualAskEntity.init(id:))
    }
}

/// What Visual Intelligence calls with the circled picture.
@available(iOS 26.0, *)
struct AnuVisualSearchQuery: IntentValueQuery {
    func values(for input: SemanticContentDescriptor) async throws -> [VisualAskEntity] {
        guard let pixels = input.pixelBuffer,
              let jpeg = pixels.withUnsafeBuffer({ VisualAsk.jpeg(from: $0) }) else { return [] }
        return [VisualAskEntity(id: try VisualAsk.stash(jpeg))]
    }
}

/// Tapping the result: opens Anu with the picture in the composer.
@available(iOS 26.0, *)
struct OpenVisualAskIntent: OpenIntent {
    static let title: LocalizedStringResource = "Ask Anu About This"
    static let description = IntentDescription("Opens Anu with the picture from Visual Intelligence, ready to ask about. Secrets on it are blacked out on this iPhone first.")
    static let isDiscoverable = false

    @Parameter(title: "Picture")
    var target: VisualAskEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let data = VisualAsk.take(target.id),
              ScreenQuestion.handOver(data, question: VisualAsk.question) else {
            throw ToolError.executionFailed("That picture is no longer available. Circle it again to ask Anu.")
        }
        NotificationCenter.default.post(name: .anuInboxUpdated, object: nil)
        return .result()
    }
}
#endif
