import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(ImagePlayground)
import ImagePlayground
#endif

/// Renders a text concept into image data (PNG). Backed by Apple's Image
/// Playground on eligible devices; a fallback throws a friendly error so the
/// agent can report unavailability instead of crashing. Injectable so tests
/// don't need a real model.
protocol ImageGenerating: Sendable {
    /// Produces PNG data for `prompt`, or throws if generation is unavailable.
    func generate(prompt: String) async throws -> Data
}

enum ImageGenerationError: LocalizedError {
    case unavailable(String)
    case noImage

    var errorDescription: String? {
        switch self {
        case .unavailable(let why): return why
        case .noImage: return "No image was produced."
        }
    }
}

/// Agent tool: lets the model create an image on request ("draw me…", "make a
/// picture of…"). On success it hands the image to `present` (which surfaces it
/// in the chat) and returns a short confirmation for the reasoning trace.
struct ImageGenerationTool: Tool {
    let name = "generate_image"
    let description = "Creates an image from a text description using on-device Image Playground. Use when the user asks to draw, generate, or make a picture/image."

    let generator: any ImageGenerating
    /// Surfaces the created image in the UI. Injected by the orchestrator.
    let present: @Sendable (Data, String) async -> Void

    init(generator: any ImageGenerating,
         present: @escaping @Sendable (Data, String) async -> Void) {
        self.generator = generator
        self.present = present
    }

    var parameters: JSONSchema? {
        .object(
            description: "Image generation parameters",
            properties: ["prompt": .string(description: "A vivid description of the image to create")],
            required: ["prompt"]
        )
    }

    func execute(arguments: JSONValue) async throws -> String {
        guard let prompt = arguments["prompt"]?.stringValue, !prompt.isEmpty else {
            throw ToolError.missingArgument("prompt")
        }
        do {
            let data = try await generator.generate(prompt: prompt)
            await present(data, prompt)
            return "Created an image for: \(prompt)"
        } catch {
            // Graceful, honest failure — no crash on ineligible devices.
            return "I couldn't create that image: \(error.localizedDescription)"
        }
    }
}

// MARK: - Generators

/// Used when Image Playground isn't compiled in or the OS is too old.
struct UnavailableImageGenerator: ImageGenerating {
    let reason: String
    func generate(prompt: String) async throws -> Data {
        throw ImageGenerationError.unavailable(reason)
    }
}

#if canImport(ImagePlayground) && canImport(UIKit)
/// Real backend: Apple's `ImageCreator` (Image Playground), iOS 18.4+. Runs the
/// generation on-device / Private Cloud Compute per Apple's pipeline.
@available(iOS 18.4, *)
struct ImagePlaygroundGenerator: ImageGenerating {
    func generate(prompt: String) async throws -> Data {
        let creator: ImageCreator
        do {
            creator = try await ImageCreator()
        } catch {
            throw ImageGenerationError.unavailable("Image generation needs Apple Intelligence on this device.")
        }
        let style = creator.availableStyles.first ?? .illustration
        for try await created in creator.images(for: [.text(prompt)], style: style, limit: 1) {
            if let data = UIImage(cgImage: created.cgImage).pngData() {
                return data
            }
        }
        throw ImageGenerationError.noImage
    }
}
#endif

/// Picks the best available generator for the current OS / SDK.
enum ImageGeneratorFactory {
    static func make() -> any ImageGenerating {
        #if canImport(ImagePlayground) && canImport(UIKit)
        if #available(iOS 18.4, *) {
            return ImagePlaygroundGenerator()
        }
        #endif
        return UnavailableImageGenerator(
            reason: "Image generation needs iOS 18.4+ with Apple Intelligence."
        )
    }
}
