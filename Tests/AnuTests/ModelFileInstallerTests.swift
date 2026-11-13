import XCTest
@testable import Anu

/// Installing a model from a file (Android ADR-067): only a catalog model is
/// kept, under its catalog name.
final class ModelFileInstallerTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("modelfile-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func model(_ name: String, size: Int64) -> AllowlistModel {
        AllowlistModel(name: name, modelId: "test/\(name)", modelFile: "\(name).litertlm", description: "",
                       sizeInBytes: size, minDeviceMemoryInGb: nil, commitHash: nil, llmSupportImage: nil,
                       llmSupportAudio: nil,
                       defaultConfig: .init(topK: 40, topP: 0.95, temperature: 0.7, maxTokens: 4096, accelerators: nil),
                       taskTypes: nil, bestForTaskTypes: nil)
    }

    private lazy var catalog = [model("small", size: 10_000), model("large", size: 50_000)]

    private func file(_ name: String, size: Int, magic: Bool = true) throws -> URL {
        var data = magic ? ModelFileInstaller.magic : Data("NOTAMODEL".utf8)
        data.append(Data(count: max(0, size - data.count)))
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testARenamedCatalogFileIsInstalledUnderItsCatalogName() throws {
        let picked = try file("gemma (1).litertlm", size: 10_000)
        let store = ModelDownloadStore(directory: dir.appendingPathComponent("Models"))
        let installed = try ModelFileInstaller.install(picked, among: catalog, store: store)
        XCTAssertEqual(installed.name, "small")
        let target = store.fileURL(for: installed)
        XCTAssertEqual(target.lastPathComponent, "small.litertlm")
        XCTAssertTrue(store.isDownloaded(installed))
        XCTAssertEqual(try target.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathExtension("installing").path))
    }

    func testASizeWithinOnePercentStillMatches() throws {
        XCTAssertEqual(try ModelFileInstaller.identify(try file("a.bin", size: 49_700), among: catalog).name, "large")
    }

    func testAnotherFileIsRefused() throws {
        XCTAssertThrowsError(try ModelFileInstaller.identify(try file("notes.txt", size: 10_000, magic: false), among: catalog)) {
            XCTAssertEqual($0 as? ModelFileInstaller.Problem, .notAModel)
        }
    }

    func testAModelThatIsntInTheCatalogIsRefused() throws {
        XCTAssertThrowsError(try ModelFileInstaller.identify(try file("other.litertlm", size: 30_000), among: catalog)) {
            XCTAssertEqual($0 as? ModelFileInstaller.Problem, .unknownModel(sizeBytes: 30_000))
        }
    }

    func testTheBundledCatalogSizesAreDistinct() {
        // identify() needs each catalog model's size to be unique within 1%.
        let sizes = ModelAllowlist.bundled.models.map(\.sizeInBytes)
        for (i, a) in sizes.enumerated() {
            for b in sizes[(i + 1)...] {
                XCTAssertGreaterThan(abs(Double(a - b)), Double(max(a, b)) * 0.02)
            }
        }
    }

    func testReinstallingReplacesTheEarlierCopy() throws {
        let store = ModelDownloadStore(directory: dir.appendingPathComponent("Models"))
        _ = try ModelFileInstaller.install(try file("one.litertlm", size: 10_000), among: catalog, store: store)
        XCTAssertNoThrow(try ModelFileInstaller.install(try file("two.litertlm", size: 10_000), among: catalog, store: store))
    }
}
