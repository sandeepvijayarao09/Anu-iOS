import Foundation

// MARK: - Model allowlist (Google AI Edge Gallery-compatible)
//
// Mirrors the schema of Gallery's `model_allowlists/ios_*.json`
// (github.com/google-ai-edge/gallery), so this type decodes that file verbatim
// and the curated `.bundled` list below is byte-compatible with the upstream
// iOS allowlist. Each entry describes a `.litertlm` model that the download
// manager can fetch from Hugging Face and the LiteRT/MediaPipe engine can run —
// the same pipeline the bundled `gemma4e4b.litertlm` already uses.

/// One downloadable model, decoded straight from Gallery's allowlist JSON.
struct AllowlistModel: Codable, Sendable, Equatable, Identifiable {
    let name: String           // "Gemma-3n-E2B-it"
    let modelId: String        // Hugging Face repo, e.g. "google/gemma-3n-E2B-it-litert-lm"
    let modelFile: String      // "gemma-3n-E2B-it-int4.litertlm"
    let description: String
    let sizeInBytes: Int64
    let minDeviceMemoryInGb: Int?
    let commitHash: String?    // pins the HF blob to an exact revision
    let llmSupportImage: Bool?
    let llmSupportAudio: Bool?
    let defaultConfig: DefaultConfig
    let taskTypes: [String]?
    let bestForTaskTypes: [String]?

    /// Stable across launches — used as the `id` and as the catalog/selection key.
    var id: String { modelId }

    /// Gallery's per-model recommended sampling + runtime config.
    struct DefaultConfig: Codable, Sendable, Equatable {
        let topK: Int
        let topP: Float
        let temperature: Float
        let maxTokens: Int
        let accelerators: String?   // "gpu" | "cpu"
    }

    /// The exact blob Gallery downloads: HF `resolve` URL pinned to the commit.
    var downloadURL: URL? {
        let ref = commitHash ?? "main"
        return URL(string: "https://huggingface.co/\(modelId)/resolve/\(ref)/\(modelFile)")
    }

    /// `google/*` Gemma repos are gated (license must be accepted) → the
    /// download needs a Hugging Face access token. Community mirrors are open.
    var requiresAuth: Bool { modelId.lowercased().hasPrefix("google/") }

    var supportsImage: Bool { llmSupportImage ?? false }
    var supportsAudio: Bool { llmSupportAudio ?? false }
}

/// The top-level allowlist document (`{ "models": [...] }`).
struct ModelAllowlist: Codable, Sendable, Equatable {
    let models: [AllowlistModel]

    /// The two Gemma 4 builds Anu runs — E2B (lighter, 8 GB RAM) and E4B
    /// (larger, 12 GB RAM). Taken verbatim from Gallery's allowlist
    /// (`model_allowlists/1_0_15.json`); both are the **open**
    /// `litert-community` LiteRT-LM builds, so no Hugging Face token is needed.
    /// Offline-first: ships in the binary so the manager has a catalog with no
    /// network round-trip. `ModelAllowlistLoader` can refresh it when online.
    static let bundled = ModelAllowlist(models: [
        AllowlistModel(
            name: "Gemma 4 E2B",
            modelId: "litert-community/gemma-4-E2B-it-litert-lm",
            modelFile: "gemma-4-E2B-it.litertlm",
            description: "Gemma 4 E2B — multimodal (text, vision, audio), up to 32K context. Lighter sibling of E4B; runs on 8 GB devices.",
            sizeInBytes: 2_588_147_712,
            minDeviceMemoryInGb: 8,
            commitHash: "6e5c4f1e395deb959c494953478fa5cec4b8008f",
            llmSupportImage: true,
            llmSupportAudio: true,
            defaultConfig: .init(topK: 64, topP: 0.95, temperature: 1.0, maxTokens: 4000, accelerators: "gpu,cpu"),
            taskTypes: ["llm_chat", "llm_prompt_lab", "llm_agent_chat", "llm_ask_image", "llm_ask_audio"],
            bestForTaskTypes: ["llm_chat", "llm_prompt_lab", "llm_agent_chat", "llm_ask_image", "llm_ask_audio"]
        ),
        AllowlistModel(
            name: "Gemma 4 E4B",
            modelId: "litert-community/gemma-4-E4B-it-litert-lm",
            modelFile: "gemma-4-E4B-it.litertlm",
            description: "Gemma 4 E4B — multimodal (text, vision, audio), up to 32K context. Open LiteRT-LM community build.",
            sizeInBytes: 3_659_530_240,
            minDeviceMemoryInGb: 12,
            commitHash: "28299f30ee4d43294517a4ac93abd6163412f07f",
            llmSupportImage: true,
            llmSupportAudio: true,
            defaultConfig: .init(topK: 64, topP: 0.95, temperature: 1.0, maxTokens: 4000, accelerators: "gpu,cpu"),
            taskTypes: ["llm_chat", "llm_prompt_lab", "llm_agent_chat", "llm_ask_image", "llm_ask_audio"],
            bestForTaskTypes: ["llm_chat", "llm_prompt_lab", "llm_agent_chat", "llm_ask_image", "llm_ask_audio"]
        ),
    ])

    func model(id: String) -> AllowlistModel? { models.first { $0.id == id } }
}

/// Decodes an allowlist from JSON (a bundled copy or a remote refresh). Kept
/// separate from `ModelAllowlist` so the type stays a pure value and this stays
/// trivially unit-testable with a `Data` blob.
enum ModelAllowlistLoader {
    static func decode(_ data: Data) throws -> ModelAllowlist {
        try JSONDecoder().decode(ModelAllowlist.self, from: data)
    }

    /// Best-effort decode; falls back to the bundled list on any failure so the
    /// catalog is never empty.
    static func decodeOrBundled(_ data: Data?) -> ModelAllowlist {
        guard let data, let list = try? decode(data), !list.models.isEmpty else {
            return .bundled
        }
        return list
    }
}
