import XCTest
@testable import Anu

/// Your own LiteRT-LM model files (AI Edge Gallery's "import a model").
final class CustomModelsTests: XCTestCase {
    private var dir: URL!
    private var source: URL!

    override func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("custom-\(UUID().uuidString)")
        dir = base.appendingPathComponent("Custom")
        source = base.appendingPathComponent("picked")
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
        super.tearDown()
    }

    private func file(_ name: String, header: String = "LITERTLM") throws -> URL {
        let url = source.appendingPathComponent(name)
        try (Data(header.utf8) + Data(repeating: 7, count: 1_000)).write(to: url)
        return url
    }

    func testInstallsListsSelectsAndDeletes() throws {
        let model = try CustomModels.install(try file("Qwen 2.5 (1.5B).litertlm"), into: dir)
        XCTAssertEqual(model.fileName, "Qwen 2.5 -1.5B-.litertlm")
        XCTAssertEqual(model.name, "Qwen 2.5 -1.5B-")
        XCTAssertEqual(model.id, "custom:Qwen 2.5 -1.5B-.litertlm")
        XCTAssertEqual(CustomModels.list(in: dir), [model])
        XCTAssertEqual(CustomModels.fileURL(for: model.id, in: dir)?.lastPathComponent, model.fileName)
        CustomModels.delete(model, in: dir)
        XCTAssertTrue(CustomModels.list(in: dir).isEmpty)
    }

    func testRefusesAFileThatIsntAModel() throws {
        XCTAssertThrowsError(try CustomModels.install(try file("notes.litertlm", header: "PK\u{3}\u{4}xxxx"), into: dir)) {
            XCTAssertEqual($0 as? ModelFileInstaller.Problem, .notAModel)
        }
    }

    func testIdsNeverLeaveTheFolder() {
        XCTAssertNil(CustomModels.fileURL(for: "custom:../../secrets.litertlm", in: dir))
        XCTAssertNil(CustomModels.fileURL(for: "automatic", in: dir))
        XCTAssertEqual(CustomModels.safeName("../a/b.bin"), "b.litertlm")
    }

    @MainActor
    func testTheManagerAcceptsACustomChoice() {
        let defaults = UserDefaults(suiteName: "custom-\(UUID().uuidString)")!
        let manager = ModelManager(defaults: defaults)
        manager.select("custom:mine.litertlm")
        XCTAssertEqual(manager.selectedID, "custom:mine.litertlm")
        manager.select("nonsense")
        XCTAssertEqual(manager.selectedID, "custom:mine.litertlm", "unknown ids are still refused")
    }
}
