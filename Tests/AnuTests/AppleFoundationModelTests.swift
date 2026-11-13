import XCTest
#if canImport(FoundationModels) && compiler(>=6.4)  // iOS 27 SDK APIs (Xcode 27)
import FoundationModels
#endif
@testable import Anu

/// Apple's models: photos, the thinking switch and the reasoning it shows.
final class AppleFoundationModelTests: XCTestCase {
    #if canImport(FoundationModels) && compiler(>=6.4)
    @available(iOS 27.0, macOS 27.0, *)
    private func segments(_ text: String) -> [Transcript.Segment] {
        [.text(Transcript.TextSegment(content: text))]
    }

    func testReasoningTextKeepsOnlyReasoningEntries() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { throw XCTSkip("needs iOS 27") }
        let entries: [Transcript.Entry] = [
            .prompt(Transcript.Prompt(segments: segments("What's 2+2?"))),
            .reasoning(Transcript.Reasoning(segments: segments("Two plus two "))),
            .reasoning(Transcript.Reasoning(segments: segments(""))),
            .reasoning(Transcript.Reasoning(segments: segments("is four."))),
            .response(Transcript.Response(assetIDs: [], segments: segments("4")))
        ]
        XCTAssertEqual(FoundationModelsTranscript.reasoningText(entries[...]), "Two plus two \n\nis four.")
        XCTAssertEqual(FoundationModelsTranscript.reasoningText(entries.prefix(1)), "", "no reasoning, no thought")
    }

    func testPrivateCloudReasonsMoreWithTheThinkingSwitch() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { throw XCTSkip("needs iOS 27") }
        let pcc = AppleFoundationModel(kind: .privateCloud)
        XCTAssertEqual(pcc.reasoningLevel(thinking: false), .moderate)
        XCTAssertEqual(pcc.reasoningLevel(thinking: true), .deep)
    }

    func testOnDeviceReasonsOnlyWhenAskedAndAble() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { throw XCTSkip("needs iOS 27") }
        let model = AppleFoundationModel(kind: .onDevice)
        XCTAssertNil(model.reasoningLevel(thinking: false), "off means Apple's default")
        XCTAssertEqual(model.reasoningLevel(thinking: true), model.supportsThinking ? .light : nil)
    }

    func testAPhotoIsRefusedOutLoudWhenTheModelCantSee() async throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { throw XCTSkip("needs iOS 27") }
        let model = AppleFoundationModel(kind: .onDevice)
        try XCTSkipIf(model.canSee, "this device's model can see; the refusal path doesn't apply")
        let pixel = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        do {
            _ = try await model.generate(prompt: "What is this?", images: [pixel], config: .default)
            XCTFail("a photo must not be silently dropped")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("can't look at pictures"), error.localizedDescription)
        }
    }
    #else
    func testAppleModelsNeedXcode27() throws { throw XCTSkip("Apple's models need the iOS 27 SDK") }
    #endif
}
