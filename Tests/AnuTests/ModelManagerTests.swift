import XCTest
@testable import Anu

@MainActor
final class ModelManagerTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "model-test-\(UUID().uuidString)")!
    }

    // MARK: - Selection / persistence

    func testDefaultSelectionIsAutomatic() {
        let m = ModelManager(defaults: freshDefaults())
        XCTAssertEqual(m.selectedID, "automatic")
        XCTAssertEqual(m.selectedOption.kind, .automatic)
    }

    func testSelectPersistsAndReloads() {
        let d = freshDefaults()
        let m = ModelManager(defaults: d)
        m.select("liteRT")
        XCTAssertEqual(m.selectedID, "liteRT")
        // A fresh manager over the same defaults restores the choice.
        XCTAssertEqual(ModelManager(defaults: d).selectedID, "liteRT")
    }

    func testSelectUnknownIDIsIgnored() {
        let m = ModelManager(defaults: freshDefaults())
        m.select("not-a-real-model")
        XCTAssertEqual(m.selectedID, "automatic")
    }

    func testOptionsCoverEveryCatalogEntry() {
        let m = ModelManager(defaults: freshDefaults())
        XCTAssertEqual(m.options.count, ModelCatalog.all.count)
    }

    // MARK: - Catalog logic (environment-independent)

    func testDownloadableIsNeedsDownload() {
        // Allowlist-derived; not fetched in the test environment → needs download.
        for dl in ModelCatalog.downloadableOptions {
            XCTAssertEqual(dl.kind, .downloadable)
            XCTAssertEqual(ModelCatalog.availability(of: dl), .needsDownload, dl.id)
        }
    }

    func testAutomaticIsAlwaysReady() {
        let auto = ModelCatalog.option(id: "automatic")!
        XCTAssertEqual(ModelCatalog.availability(of: auto), .ready)
    }

    func testKindFallsBackForUnknownID() {
        XCTAssertEqual(ModelCatalog.kind(forID: "bogus"), .automatic)
        XCTAssertEqual(ModelCatalog.kind(forID: "liteRT"), .liteRT)
        // Retired ids (Core ML, Apple, Private Compute) fall back, so anyone
        // who had one persisted lands on Automatic instead of a dead backend.
        XCTAssertEqual(ModelCatalog.kind(forID: "appleFoundation"), .automatic)
        XCTAssertEqual(ModelCatalog.kind(forID: "coreML"), .automatic)
        XCTAssertEqual(ModelCatalog.kind(forID: "privateCloud"), .automatic)
    }

    // MARK: - Catalog is Apple on-device + Gemma 4 (parity A1)

    func testCatalogOffersAppleAndGemma4() {
        let names = ModelCatalog.all.map(\.displayName)
        XCTAssertEqual(names, ["Automatic", "Apple on-device", "Gemma 4 E4B", "Gemma 4 E2B", "Gemma 4 E4B"])
        XCTAssertTrue(ModelCatalog.all.allSatisfy { $0.kind != .downloadable || $0.id.hasPrefix("dl:") })
    }

    func testAllowlistIsExactlyE2BAndE4B() {
        XCTAssertEqual(ModelCatalog.allowlist.models.map(\.modelId), [
            "litert-community/gemma-4-E2B-it-litert-lm",
            "litert-community/gemma-4-E4B-it-litert-lm",
        ])
        // Both are open community mirrors — no Hugging Face token needed.
        XCTAssertTrue(ModelCatalog.allowlist.models.allSatisfy { !$0.requiresAuth })
    }

    // MARK: - Factory honors the selection (with safe fallback)

    func testFactoryHonorsDownloadableSelectionAndFailsLoudly() async {
        let key = ModelManager.selectionKey
        let saved = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(ModelCatalog.downloadableOptions.first!.id, forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let model = ModelFactory.makeModel()
        do {
            _ = try await model.load()
            XCTFail("a not-downloaded model must not load")
        } catch {
            // UnavailableModel surfaces a clear reason instead of crashing.
            XCTAssertTrue("\(error)".lowercased().contains("download"), "\(error)")
        }
    }
}
