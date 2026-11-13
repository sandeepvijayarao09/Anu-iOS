import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The model the writing extensions can run in their own process: Apple's
/// on-device Foundation Models (iOS 26+, Apple Intelligence on). The model
/// itself lives in a system process, so it costs the extension little memory,
/// and nothing leaves the device. Gemma never loads in an extension; without
/// Apple's model the extension hands the text to the Anu app instead.
enum ExtensionWriting {
    /// Apple's model's context window, in tokens (prompt plus answer).
    static let appleContextTokens = 4_096

    /// Apple's on-device engine when it's ready, else nil.
    static func appleEngine() -> (any WritingEngine)? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return AppleWritingEngine()
            }
        }
        #endif
        return nil
    }

    /// Why Apple's model can't run here, in a sentence for the user.
    static var unavailableReason: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return ""
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Apple Intelligence is turned off in Settings."
            case .unavailable(.modelNotReady):
                return "Apple's on-device model is still downloading."
            case .unavailable(.deviceNotEligible):
                return "This device doesn't run Apple's on-device model."
            default:
                return "Apple's on-device model isn't available right now."
            }
        }
        #endif
        return "Apple's on-device model needs iOS 26 or later."
    }

    /// Whether a request fits Apple's model's context window.
    static func fitsApple(_ spec: WritingPromptSpec) -> Bool {
        WritingPrompt.estimatedTokens(spec.system + spec.user) + spec.maxTokens <= appleContextTokens - 256
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
struct AppleWritingEngine: WritingEngine {
    let name = "Apple Intelligence"

    func write(_ spec: WritingPromptSpec) async throws -> String {
        // A fresh session per task: no history, no tools.
        let session = LanguageModelSession(instructions: spec.system)
        let options = GenerationOptions(samplingMode: spec.precise ? .greedy : nil,
                                            maximumResponseTokens: spec.maxTokens)
        let response = try await session.respond(to: spec.user, options: options)
        return response.content
    }
}
#endif
