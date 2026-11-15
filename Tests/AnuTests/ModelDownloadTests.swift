import XCTest
@testable import Anu

/// Covers the Gallery-style download pipeline's pure, device-independent logic:
/// allowlist decoding, HF URL/auth derivation, on-disk state, and the download
/// manager's reconcile/delete reducers. The actual URLSession transfer is not
/// exercised here (it needs the network + multi-GB blobs).
final class ModelDownloadTests: XCTestCase {

    // MARK: - Allowlist decoding (Gallery-compatible schema)

    private let galleryJSON = """
    { "models": [
      {
        "name": "Gemma-3n-E2B-it",
        "modelId": "google/gemma-3n-E2B-it-litert-lm",
        "modelFile": "gemma-3n-E2B-it-int4.litertlm",
        "description": "desc",
        "sizeInBytes": 3388604416,
        "minDeviceMemoryInGb": 6,
        "commitHash": "73b019b63436d346f68dd9c1dbfd117eb264d888",
        "llmSupportImage": true,
        "llmSupportAudio": true,
        "defaultConfig": { "topK": 64, "topP": 0.95, "temperature": 1.0, "maxTokens": 4096, "accelerators": "gpu" },
        "taskTypes": ["llm_chat", "llm_ask_image"],
        "bestForTaskTypes": ["llm_ask_image"]
      }
    ] }
    """

    func testDecodesGalleryAllowlistJSON() throws {
        let list = try ModelAllowlistLoader.decode(Data(galleryJSON.utf8))
        XCTAssertEqual(list.models.count, 1)
        let m = list.models[0]
        XCTAssertEqual(m.name, "Gemma-3n-E2B-it")
        XCTAssertEqual(m.modelId, "google/gemma-3n-E2B-it-litert-lm")
        XCTAssertEqual(m.modelFile, "gemma-3n-E2B-it-int4.litertlm")
        XCTAssertEqual(m.sizeInBytes, 3_388_604_416)
        XCTAssertEqual(m.minDeviceMemoryInGb, 6)
        XCTAssertEqual(m.defaultConfig.maxTokens, 4096)
        XCTAssertEqual(m.defaultConfig.topK, 64)
        XCTAssertTrue(m.supportsImage)
        XCTAssertTrue(m.supportsAudio)
    }

    func testDecodeOrBundledFallsBackOnNilAndGarbage() {
        XCTAssertEqual(ModelAllowlistLoader.decodeOrBundled(nil), ModelAllowlist.bundled)
        XCTAssertEqual(ModelAllowlistLoader.decodeOrBundled(Data("not json".utf8)), ModelAllowlist.bundled)
    }

    func testBundledAllowlistIsGemma4E2BAndE4BOnly() {
        XCTAssertEqual(ModelAllowlist.bundled.models.map(\.modelId),
                       ["litert-community/gemma-4-E2B-it-litert-lm",
                        "litert-community/gemma-4-E4B-it-litert-lm"])
    }

    func testE2BEntryMatchesGalleryAllowlist() {
        let m = ModelAllowlist.bundled.model(id: "litert-community/gemma-4-E2B-it-litert-lm")!
        XCTAssertEqual(m.modelFile, "gemma-4-E2B-it.litertlm")
        XCTAssertEqual(m.sizeInBytes, 2_588_147_712)
        XCTAssertEqual(m.minDeviceMemoryInGb, 8)
        XCTAssertEqual(m.commitHash, "6e5c4f1e395deb959c494953478fa5cec4b8008f")
        XCTAssertTrue(m.supportsImage)
        XCTAssertTrue(m.supportsAudio)
        // Community mirror, not the gated `google/*` repo → no HF token needed.
        XCTAssertFalse(m.requiresAuth)
        XCTAssertEqual(
            m.downloadURL?.absoluteString,
            "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/6e5c4f1e395deb959c494953478fa5cec4b8008f/gemma-4-E2B-it.litertlm")
    }

    // MARK: - URL + auth derivation

    func testDownloadURLPinsToCommit() {
        let m = ModelAllowlist.bundled.model(id: "litert-community/gemma-4-E4B-it-litert-lm")!
        XCTAssertEqual(
            m.downloadURL?.absoluteString,
            "https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/28299f30ee4d43294517a4ac93abd6163412f07f/gemma-4-E4B-it.litertlm"
        )
        // The URL's last path component equals modelFile — the delegate relies
        // on this to reconstruct the destination off the main actor.
        XCTAssertEqual(m.downloadURL?.lastPathComponent, m.modelFile)
    }

    func testRequiresAuthForGatedGoogleReposOnly() {
        // The shipped Gemma 4 E4B is an open community mirror — no token.
        XCTAssertFalse(ModelAllowlist.bundled.model(id: "litert-community/gemma-4-E4B-it-litert-lm")!.requiresAuth)
        // A gated google/* repo still demands one.
        XCTAssertTrue(syntheticGatedModel().requiresAuth)
    }

    // MARK: - Catalog wiring

    func testCatalogExposesAllowlistAsDownloadables() {
        XCTAssertEqual(ModelCatalog.downloadableOptions.count, ModelAllowlist.bundled.models.count)
        let opt = ModelCatalog.downloadableOptions[0]
        XCTAssertTrue(opt.id.hasPrefix(ModelCatalog.downloadablePrefix))
        // Round-trips option id → allowlist model.
        XCTAssertEqual(ModelCatalog.allowlistModel(forOptionID: opt.id)?.id,
                       String(opt.id.dropFirst(ModelCatalog.downloadablePrefix.count)))
    }

    func testAllowlistModelLookupRejectsNonDownloadableIDs() {
        XCTAssertNil(ModelCatalog.allowlistModel(forOptionID: "automatic"))
        XCTAssertNil(ModelCatalog.allowlistModel(forOptionID: "liteRT"))
    }

    // MARK: - Store (on-disk presence)

    private func tempStore() -> (ModelDownloadStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-dl-\(UUID().uuidString)", isDirectory: true)
        return (ModelDownloadStore(directory: dir), dir)
    }

    /// A tiny synthetic model so "downloaded" can be simulated with a small file.
    private func tinyModel(size: Int64) -> AllowlistModel {
        AllowlistModel(
            name: "Tiny", modelId: "test/tiny", modelFile: "tiny.litertlm",
            description: "", sizeInBytes: size, minDeviceMemoryInGb: 1, commitHash: "abc",
            llmSupportImage: false, llmSupportAudio: false,
            defaultConfig: .init(topK: 1, topP: 1, temperature: 1, maxTokens: 8, accelerators: "cpu"),
            taskTypes: nil, bestForTaskTypes: nil)
    }

    /// A synthetic gated `google/*` model — exercises the auth-gating path even
    /// though the shipped allowlist is now an open mirror.
    private func syntheticGatedModel() -> AllowlistModel {
        AllowlistModel(
            name: "Gated", modelId: "google/some-gated-model", modelFile: "gated.litertlm",
            description: "", sizeInBytes: 100, minDeviceMemoryInGb: 1, commitHash: "abc",
            llmSupportImage: false, llmSupportAudio: false,
            defaultConfig: .init(topK: 1, topP: 1, temperature: 1, maxTokens: 8, accelerators: "cpu"),
            taskTypes: nil, bestForTaskTypes: nil)
    }

    func testStoreDownloadPresenceAndDelete() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = tinyModel(size: 100)

        XCTAssertFalse(store.isDownloaded(model))

        // A too-small file (partial download) does not count as present.
        try store.ensureDirectory()
        try Data(repeating: 0, count: 50).write(to: store.fileURL(for: model))
        XCTAssertFalse(store.isDownloaded(model))

        // A full-size file counts as present.
        try Data(repeating: 0, count: 100).write(to: store.fileURL(for: model))
        XCTAssertTrue(store.isDownloaded(model))

        store.delete(model)
        XCTAssertFalse(store.isDownloaded(model))
    }

    // MARK: - Manager reconcile/delete reducers

    @MainActor
    func testManagerReflectsDiskStateAndDelete() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = tinyModel(size: 100)
        let manager = ModelDownloadManager(store: store,
                                            allowlist: ModelAllowlist(models: [model]))

        // Nothing on disk yet.
        XCTAssertEqual(manager.state(for: model), .notDownloaded)

        // Place a complete file and reconcile.
        try store.ensureDirectory()
        try Data(repeating: 0, count: 100).write(to: store.fileURL(for: model))
        manager.refreshStatesFromDisk()
        XCTAssertEqual(manager.state(for: model), .downloaded)

        // Delete removes the file and resets state.
        manager.delete(model)
        XCTAssertEqual(manager.state(for: model), .notDownloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: model).path))
    }

    @MainActor
    func testGatedDownloadWithoutTokenFailsLoudly() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gated = syntheticGatedModel()
        let manager = ModelDownloadManager(store: store, allowlist: ModelAllowlist(models: [gated]))

        manager.huggingFaceToken = nil
        manager.download(gated)   // must not start a transfer

        guard case .failed(let msg) = manager.state(for: gated) else {
            return XCTFail("gated download without a token should fail loudly, got \(manager.state(for: gated))")
        }
        XCTAssertTrue(msg.lowercased().contains("token"), msg)
    }

    @MainActor
    func testTokenPersistsAndClears() {
        let manager = ModelDownloadManager(store: tempStore().0, allowlist: .bundled)
        manager.huggingFaceToken = "  hf_secret  "
        XCTAssertEqual(manager.huggingFaceToken, "hf_secret")   // trimmed
        manager.huggingFaceToken = "   "
        XCTAssertNil(manager.huggingFaceToken)                  // blank clears
        UserDefaults.standard.removeObject(forKey: ModelDownloadManager.tokenKey)
    }

    /// Speed and time left, like Gallery's download row.
    func testDownloadPaceSaysSpeedAndTimeLeft() {
        let start = Date(timeIntervalSince1970: 0)
        let gb: Int64 = 1_000_000_000
        XCTAssertEqual(DownloadPace.text(progress: 0.1, since: nil, now: start, totalBytes: gb), "10% of 1.0 GB")
        let text = DownloadPace.text(progress: 0.5, since: (start, 0.0), now: start.addingTimeInterval(100), totalBytes: gb)
        XCTAssertTrue(text.hasPrefix("50% of 1.0 GB · 5 MB/s"), text)
        XCTAssertTrue(text.hasSuffix("about 2 min left"), text)
        let nearly = DownloadPace.text(progress: 0.99, since: (start, 0.0), now: start.addingTimeInterval(99), totalBytes: gb)
        XCTAssertTrue(nearly.hasSuffix("under a minute left"), nearly)
    }
}
