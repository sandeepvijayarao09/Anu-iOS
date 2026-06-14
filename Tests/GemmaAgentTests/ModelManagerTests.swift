import XCTest
@testable import GemmaAgent

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
        let dl = ModelCatalog.option(id: "dl_llama32_3b")!
        XCTAssertEqual(ModelCatalog.availability(of: dl), .needsDownload)
    }

    func testAutomaticIsAlwaysReady() {
        let auto = ModelCatalog.option(id: "automatic")!
        XCTAssertEqual(ModelCatalog.availability(of: auto), .ready)
    }

    func testKindFallsBackForUnknownID() {
        XCTAssertEqual(ModelCatalog.kind(forID: "bogus"), .automatic)
        XCTAssertEqual(ModelCatalog.kind(forID: "appleFoundation"), .appleFoundation)
    }

    // MARK: - Factory honors the selection (with safe fallback)

    func testFactoryHonorsDownloadableSelectionAndFailsLoudly() async {
        let key = ModelManager.selectionKey
        let saved = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set("dl_llama32_3b", forKey: key)
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
