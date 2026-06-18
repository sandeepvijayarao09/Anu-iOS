import XCTest
@testable import Anu

private struct OKGenerator: ImageGenerating {
    let data: Data
    func generate(prompt: String) async throws -> Data { data }
}

private struct FailingGenerator: ImageGenerating {
    func generate(prompt: String) async throws -> Data {
        throw ImageGenerationError.unavailable("needs Apple Intelligence")
    }
}

private actor PresentRecorder {
    private(set) var captions: [String] = []
    func record(_ caption: String) { captions.append(caption) }
    func count() -> Int { captions.count }
    func last() -> String? { captions.last }
}

final class ImageGenerationToolTests: XCTestCase {

    func testSuccessPresentsImageAndConfirms() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let recorder = PresentRecorder()
        let tool = ImageGenerationTool(generator: OKGenerator(data: png)) { _, caption in
            await recorder.record(caption)
        }
        let out = try await tool.execute(arguments: .object(["prompt": .string("a red bicycle")]))
        XCTAssertTrue(out.contains("a red bicycle"), out)
        let count = await recorder.count()
        XCTAssertEqual(count, 1)
        let last = await recorder.last()
        XCTAssertEqual(last, "a red bicycle")
    }

    func testUnavailableReportsGracefullyWithoutPresenting() async throws {
        let recorder = PresentRecorder()
        let tool = ImageGenerationTool(generator: FailingGenerator()) { _, caption in
            await recorder.record(caption)
        }
        let out = try await tool.execute(arguments: .object(["prompt": .string("a cat")]))
        XCTAssertTrue(out.lowercased().contains("couldn't create"), out)
        XCTAssertTrue(out.contains("needs Apple Intelligence"), out)
        let count = await recorder.count()
        XCTAssertEqual(count, 0, "nothing should be surfaced when generation fails")
    }

    func testMissingPromptThrows() async {
        let tool = ImageGenerationTool(generator: OKGenerator(data: Data())) { _, _ in }
        do {
            _ = try await tool.execute(arguments: .object([:]))
            XCTFail("expected a missing-argument throw")
        } catch { /* expected */ }
    }

    func testUnavailableGeneratorThrowsReason() async {
        let gen = UnavailableImageGenerator(reason: "no AI here")
        do {
            _ = try await gen.generate(prompt: "x")
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no AI here"))
        }
    }
}
