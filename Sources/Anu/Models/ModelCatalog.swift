import Foundation

// MARK: - Model catalog
//
// Describes every brain the app can run behind the `LocalLanguageModel`
// protocol — Apple's on-device model (Foundation Models, iOS/macOS 27) and
// Gemma 4 E2B and E4B on LiteRT-LM. The catalog is
// the single source of truth for the Model Manager UI and for resolving the
// user's `selected_model` choice in `ModelFactory`.

/// Which backend a catalog entry maps to.
enum ModelBackendKind: String, Sendable, Equatable {
    case automatic        // priority chain (Apple on-device → bundled LiteRT → downloaded LiteRT → Unavailable)
    case appleOnDevice    // Apple's on-device model via Foundation Models (parity A1)
    case liteRT           // bundled Gemma 4 E4B via Google LiteRT-LM
    case downloadable     // a Gallery-allowlist .litertlm model, fetched on demand
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
    /// Prefix on a downloadable option's `id`, followed by the allowlist
    /// `modelId` (e.g. `dl:litert-community/gemma-4-E2B-it-litert-lm`). Lets the factory
    /// map a persisted selection back to its `AllowlistModel`.
    static let downloadablePrefix = "dl:"

    /// Source of the downloadable entries — the curated, Gallery-compatible
    /// iOS allowlist. (Remote refresh via `ModelAllowlistLoader` is a future
    /// enhancement; the catalog stays on the bundled list for stable ids.)
    static let allowlist = ModelAllowlist.bundled

    // MARK: Fixed (non-downloadable) entries

    static let automaticOption = ModelOption(
        id: "automatic", displayName: "Automatic", family: "Recommended",
        sizeText: "—", ramText: "Apple when available, else Gemma", speedText: "Best available",
        kind: .automatic)

    static let appleOption = ModelOption(
        id: "apple", displayName: "Apple on-device", family: "Apple Intelligence",
        sizeText: "Built in", ramText: "Apple Intelligence devices", speedText: "Fast · 4K context",
        kind: .appleOnDevice)

    static let liteRTOption = ModelOption(
        id: "liteRT", displayName: "Gemma 4 E4B", family: "Google · LiteRT",
        sizeText: "3.4 GB", ramText: "≥ 12 GB RAM", speedText: "Fast (KV-cached)",
        kind: .liteRT)

    /// Downloadable entries, derived from the allowlist so display name, size,
    /// and RAM requirement always match what we actually fetch.
    static var downloadableOptions: [ModelOption] {
        allowlist.models.map { model in
            ModelOption(
                id: downloadablePrefix + model.id,
                displayName: model.name,
                family: "Google · LiteRT",
                sizeText: gbText(model.sizeInBytes),
                ramText: model.minDeviceMemoryInGb.map { "≥ \($0) GB RAM" } ?? "—",
                speedText: (model.defaultConfig.accelerators == "gpu") ? "Fast (GPU)" : "CPU",
                kind: .downloadable)
        }
    }

    /// Curated list: Gemma 4 only. `automatic` is the recommended default and
    /// always selectable; the bundled E4B entry is available when its resource
    /// ships in the app; downloadables (E2B, E4B) are ready once fetched.
    static var all: [ModelOption] {
        [automaticOption, appleOption, liteRTOption] + downloadableOptions
    }

    static func option(id: String) -> ModelOption? {
        all.first { $0.id == id }
    }

    /// The backend kind for a persisted selection, defaulting to `.automatic`
    /// for unknown ids (safe fallback).
    static func kind(forID id: String) -> ModelBackendKind {
        option(id: id)?.kind ?? .automatic
    }

    /// The allowlist model behind a downloadable option id, if any.
    static func allowlistModel(forOptionID id: String) -> AllowlistModel? {
        guard id.hasPrefix(downloadablePrefix) else { return nil }
        return allowlist.model(id: String(id.dropFirst(downloadablePrefix.count)))
    }

    static func gbText(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    /// Live availability for one option, mirroring the Bundle/OS checks in
    /// `ModelFactory.makeModel()`.
    static func availability(of option: ModelOption) -> ModelAvailability {
        switch option.kind {
        case .automatic:
            return .ready
        case .appleOnDevice:
            let status = AppleModels.status(of: .onDevice)
            return status.isUsable ? .ready : .unsupported(status.reason?.userText ?? "Unavailable")
        case .liteRT:
            #if canImport(LiteRTLM)
            return Bundle.main.path(forResource: "gemma4e4b", ofType: "litertlm") != nil
                ? .ready : .unsupported("Not bundled — download Gemma 4 E4B below")
            #else
            return .unsupported("LiteRT-LM engine not in this build")
            #endif
        case .downloadable:
            #if canImport(LiteRTLM)
            guard let model = allowlistModel(forOptionID: option.id) else { return .needsDownload }
            return ModelDownloadStore().isDownloaded(model) ? .ready : .needsDownload
            #else
            return .unsupported("LiteRT-LM engine not in this build")
            #endif
        }
    }
}
