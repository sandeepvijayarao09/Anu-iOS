import Foundation
import Vision
import ImageIO
import CoreGraphics

/// On-device OCR via the Vision framework — fully offline, no network. Pure and
/// `nonisolated` so it's directly unit-testable with a rendered fixture image.
enum TextRecognizer {
    static func recognizeText(in cgImage: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil else { return "" }
        let observations = request.results as? [VNRecognizedTextObservation] ?? []
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    static func recognizeText(inFileAt url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return recognizeText(in: image)
    }
}

/// Extracts text from an image file (receipts, screenshots, signs) using
/// on-device Vision OCR. Works offline; nothing leaves the device.
struct ReadTextTool: Tool {
    let name = "read_text"
    let description = """
    Read the text in an image file (OCR) — receipts, screenshots, documents, signs. \
    Fully on-device. Provide 'path' to a png/jpg image file.
    """

    var parameters: JSONSchema? {
        .object(
            description: "OCR parameters",
            properties: ["path": .string(description: "Path to an image file (png/jpg)")],
            required: ["path"]
        )
    }

    func execute(arguments: JSONValue) async throws -> String {
        guard let path = arguments["path"]?.stringValue, !path.isEmpty else {
            throw ToolError.missingArgument("path")
        }
        guard let text = TextRecognizer.recognizeText(inFileAt: URL(fileURLWithPath: path)) else {
            return "Couldn't open that image file."
        }
        return text.isEmpty ? "No text found in the image." : "Text found:\n\(text)"
    }
}
