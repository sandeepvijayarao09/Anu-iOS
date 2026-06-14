import Foundation

// MARK: - Apple Foundation Models backend
//
// The "judo move": Apple's on-device model becomes one more option behind our
// own `LocalLanguageModel` protocol. It needs no native tool wiring — the
// ReAct/JSON tool protocol already lives in the prompt and `ResponseParser`
// parses the streamed text, exactly like the LiteRT and Core ML backends.
//
// Everything that touches the framework is gated behind `#if canImport` +
// `@available(iOS 26, *)`. `FoundationModelSupport.availability` (below) gives
// the rest of the app a uniform answer without sprinkling `#if` everywhere.

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26, *)
actor FoundationModelBackend: LocalLanguageModel {
    nonisolated let modelName = "Apple On-device"

    private var session: LanguageModelSession?

    func load() async throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            session = LanguageModelSession()
        case .unavailable(let reason):
            throw ModelError.modelLoadFailed(FoundationModelSupport.describe(reason))
        @unknown default:
            throw ModelError.modelLoadFailed("Apple Intelligence is unavailable")
        }
    }

    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String> {
        guard let session else {
            throw ModelError.modelLoadFailed("Apple on-device model isn't loaded")
        }
        let options = GenerationOptions(temperature: Double(config.temperature))

        return AsyncStream<String> { continuation in
            // Inherits the actor's executor, so `session` is reachable directly.
            let producer = Task {
                var emitted = 0
                do {
                    let stream = session.streamResponse(to: prompt, options: options)
                    for try await partial in stream {
                        if Task.isCancelled { break }
                        // FM yields CUMULATIVE snapshots; emit only the new suffix
                        // so it composes with the UI's append-based streaming.
                        let full = partial.content
                        if full.count > emitted {
                            let start = full.index(full.startIndex, offsetBy: emitted)
                            continuation.yield(String(full[start...]))
                            emitted = full.count
                        }
                    }
                } catch {
                    // End the stream quietly; the orchestrator surfaces empties.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
}
#endif

// MARK: - Uniform availability probe

/// Single place the catalog/UI asks "can we use Apple's model?" — resolves to a
/// `ModelAvailability` whether or not the framework is present in this build.
enum FoundationModelSupport {
    static var availability: ModelAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .ready
            case .unavailable(let reason):
                return .unsupported(describe(reason))
            @unknown default:
                return .unsupported("Apple Intelligence is unavailable")
            }
        } else {
            return .unsupported("Requires iOS 26 or later")
        }
        #else
        return .unsupported("Not built with Apple Intelligence support")
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26, *)
    static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This device doesn't support Apple Intelligence"
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings"
        case .modelNotReady:
            return "The Apple model is still downloading — try again shortly"
        @unknown default:
            return "Apple Intelligence is unavailable"
        }
    }
    #endif
}
