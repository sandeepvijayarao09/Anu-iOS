import XCTest
@testable import Anu

/// Matches with Google AI Edge Gallery: the chat's model menu and the
/// accelerator choice.
@MainActor
final class GalleryParityTests: XCTestCase {
    func testTheChatMenuOffersOnlyReadyModelsThenYourOwn() {
        let options: [(option: ModelOption, availability: ModelAvailability)] = [
            (ModelCatalog.automaticOption, .ready),
            (ModelCatalog.appleOption, .unsupported("Needs Apple Intelligence")),
            (ModelCatalog.liteRTOption, .ready),
        ]
        let mine = CustomModels.Model(fileName: "my-model.litertlm", sizeBytes: 1)
        let choices = ChatModelMenu.choices(options, custom: [mine])
        XCTAssertEqual(choices.map(\.id), ["automatic", "liteRT", mine.id])
        XCTAssertEqual(choices.map(\.name), ["Automatic", "Gemma 4 E4B", "my-model"])
    }

    func testTheAcceleratorDefaultsToGPUWhereItCanChoose() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "accel-\(UUID().uuidString)"))
        #if targetEnvironment(simulator)
        defaults.set("gpu", forKey: ModelAccelerator.key)
        XCTAssertEqual(ModelAccelerator.current(defaults), .cpu, "the simulator can only use the CPU")
        #else
        XCTAssertEqual(ModelAccelerator.current(defaults), .gpu)
        defaults.set("cpu", forKey: ModelAccelerator.key)
        XCTAssertEqual(ModelAccelerator.current(defaults), .cpu)
        #endif
    }
}
