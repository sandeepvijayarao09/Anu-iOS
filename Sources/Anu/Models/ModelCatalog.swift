import Foundation

// MARK: - Model catalog
//
// Describes every brain the app can run behind the `LocalLanguageModel`
// protocol. The catalog is the single source of truth for the Model Manager UI
// and for resolving the user's `selected_model` choice in `ModelFactory`.

/// Which backend a catalog entry maps to.
enum ModelBackendKind: String, Sendable, Equatable {
    case automatic        // today's priority chain (LiteRT → Core ML → Unavailable)
    case liteRT           // bundled Gemma 4 E4B via Google LiteRT
    case coreML           // bundled Gemma 3 4B via Core ML (iOS 18+)
    case appleFoundation  // Apple's on-device model via FoundationModels
    case downloadable     // curated, not bundled — listed for the openness story
    case privateCloud     // streams from a private compute server you operate
}

/// Whether an entry can run right now.
enum ModelAvailability: Equatable {
    case ready
    case needsDownload
    case unsupported(String)   // reason shown in the UI

    var isReady: Bool { self == .ready }
}

/// One selectable model in the manager.
struct ModelOption: Identifiable, Sendable, Equatable {
    let id: String          // stable key persisted in `selected_model`
    let displayName: String
    let family: String
    let sizeText: String
    let ramText: String
    let speedText: String
    let kind: ModelBackendKind
}

enum ModelCatalog {
    /// Curated list. The first entry (`automatic`) is the recommended default
    /// and always selectable; bundled entries are available when their resource
    /// is present; Apple is available when the device supports it; downloadables
    /// are list-only (the openness story without the download plumbing).
    static let all: [ModelOption] = [
        ModelOption(id: "automatic", displayName: "Automatic", family: "Recommended",
                    sizeText: "—", ramText: "Adapts to device", speedText: "Best available",
                    kind: .automatic),
        ModelOption(id: "liteRT", displayName: "Gemma 4 E4B", family: "Google · LiteRT",
                    sizeText: "3.4 GB", ramText: "≥ 6 GB RAM", speedText: "Fast (KV-cached)",
                    kind: .liteRT),
        ModelOption(id: "coreML", displayName: "Gemma 3 4B", family: "Google · Core ML",
                    sizeText: "2.3 GB", ramText: "≥ 6 GB RAM", speedText: "Slower (no KV cache)",
                    kind: .coreML),
        ModelOption(id: "appleFoundation", displayName: "Apple On-device", family: "Apple Intelligence",
                    sizeText: "Built in", ramText: "Managed by iOS", speedText: "Fast (ANE)",
                    kind: .appleFoundation),
        ModelOption(id: "dl_llama32_3b", displayName: "Llama 3.2 3B", family: "Meta",
                    sizeText: "~1.9 GB", ramText: "≥ 6 GB RAM", speedText: "Fast",
                    kind: .downloadable),
        ModelOption(id: "dl_qwen25_3b", displayName: "Qwen 2.5 3B", family: "Alibaba",
                    sizeText: "~1.9 GB", ramText: "≥ 6 GB RAM", speedText: "Fast",
                    kind: .downloadable),
        ModelOption(id: "dl_phi35_mini", displayName: "Phi-3.5 mini", family: "Microsoft",
                    sizeText: "~2.2 GB", ramText: "≥ 6 GB RAM", speedText: "Fast",
                    kind: .downloadable),
        ModelOption(id: "privateCloud", displayName: "Private Compute", family: "Your Server",
                    sizeText: "Remote", ramText: "Server-side", speedText: "Network",
                    kind: .privateCloud),
    ]

    static func option(id: String) -> ModelOption? {
        all.first { $0.id == id }
    }

    /// The backend kind for a persisted selection, defaulting to `.automatic`
    /// for unknown ids (safe fallback).
    static func kind(forID id: String) -> ModelBackendKind {
        option(id: id)?.kind ?? .automatic
    }

    /// Live availability for one option, mirroring the Bundle/OS checks in
    /// `ModelFactory.makeModel()`.
    static func availability(of option: ModelOption) -> ModelAvailability {
        switch option.kind {
        case .automatic:
            return .ready
        case .liteRT:
            #if canImport(MediaPipeTasksGenAI)
            return Bundle.main.path(forResource: "gemma4e4b", ofType: "litertlm") != nil
                ? .ready : .unsupported("Not bundled in this build")
            #else
            return .unsupported("LiteRT engine not in this build")
            #endif
        case .coreML:
            let present =
                Bundle.main.url(forResource: "gemma4b", withExtension: "mlpackage") != nil ||
                Bundle.main.url(forResource: "gemma4b", withExtension: "mlmodelc") != nil
            guard present else { return .unsupported("Not bundled in this build") }
            if #available(iOS 18, *) { return .ready }
            return .unsupported("Requires iOS 18 or later")
        case .appleFoundation:
            return FoundationModelSupport.availability
        case .downloadable:
            return .needsDownload
        case .privateCloud:
            return PrivateComputeClient().isConfigured
                ? .ready
                : .unsupported("Add a server endpoint in Settings → Private Compute")
        }
    }
}
