import XCTest
import CoreGraphics
import CoreText
@testable import Anu

/// Live camera (parity row 22). The simulator has no camera, so detection,
/// throttling, matching and box geometry run on still images drawn here.
final class LiveCameraTests: XCTestCase {

    // MARK: Still images

    /// A light rectangle (top-left normalized `box`) on a dark background.
    private func rectangleImage(size: CGSize = CGSize(width: 640, height: 480), box: CGRect) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.9, alpha: 1))
        // CoreGraphics is bottom-left; flip the top-left box.
        ctx.fill(CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                        width: box.width * size.width, height: box.height * size.height))
        return ctx.makeImage()!
    }

    private func textImage(_ text: String) -> CGImage {
        let size = CGSize(width: 800, height: 300)
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 140, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        ctx.textPosition = CGPoint(x: 60, y: 100)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        return ctx.makeImage()!
    }

    private func det(_ label: String, _ c: Float, _ box: CGRect = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                     _ source: LiveDetection.Source = .model) -> LiveDetection {
        LiveDetection(label: label, confidence: c, box: box, source: source)
    }

    // MARK: Vision detection on stills

    func testVisionFindsARectangleWhereItWasDrawn() throws {
        let box = CGRect(x: 0.25, y: 0.2, width: 0.45, height: 0.5)
        let detector = VisionLiveDetector()
        detector.includeText = false
        detector.sceneEvery = 0
        let found = try detector.detect(in: rectangleImage(box: box))
        let rect = try XCTUnwrap(found.first { $0.source == .rectangle }, "found: \(found.map(\.caption))")
        XCTAssertGreaterThan(LiveBoxGeometry.iou(rect.box, box), 0.8, "box \(rect.box) vs drawn \(box)")
        XCTAssertFalse(found.contains { $0.source == .animal || $0.source == .person })
    }

    func testVisionReadsTextInAFrame() throws {
        let detector = VisionLiveDetector()
        detector.sceneEvery = 0
        let found = try detector.detect(in: textImage("EXIT"))
        let text = found.filter { $0.source == .text }
        XCTAssertTrue(text.contains { $0.label.uppercased().contains("EXIT") }, "found: \(found.map(\.caption))")
        XCTAssertEqual(text.first?.matchKey, "text")
    }

    func testBlankFrameFindsNothing() throws {
        let detector = VisionLiveDetector()
        detector.sceneEvery = 0
        let ctx = CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        XCTAssertTrue(try detector.detect(in: ctx.makeImage()!).isEmpty)
    }

    func testFactoryFallsBackToAppleVisionWithoutABundledModel() {
        let detector = LiveDetectorFactory.make(bundle: Bundle(for: Self.self))
        XCTAssertEqual(detector.name, "Apple Vision")
        XCTAssertTrue(detector.vocabulary.contains("cat"))
        XCTAssertEqual(LiveDetectorFactory.cocoLabels.count, 80)
    }

    // MARK: Geometry

    func testVisionRectFlipsToTopLeft() {
        let r = LiveBoxGeometry.topLeft(fromVision: CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3))
        XCTAssertEqual(r.minX, 0.1, accuracy: 1e-9)
        XCTAssertEqual(r.minY, 0.1, accuracy: 1e-9)
        XCTAssertEqual(r.height, 0.3, accuracy: 1e-9)
    }

    func testAspectFillCropsTheLongerSide() {
        // 3:4 portrait frame on a 390×844 screen: height fills, width overflows.
        let full = LiveBoxGeometry.viewRect(for: CGRect(x: 0, y: 0, width: 1, height: 1),
                                            imageSize: CGSize(width: 1080, height: 1440),
                                            in: CGSize(width: 390, height: 844))
        XCTAssertEqual(full.height, 844, accuracy: 0.01)
        XCTAssertEqual(full.width, 633, accuracy: 0.01)
        XCTAssertEqual(full.midX, 195, accuracy: 0.01)
        let centre = LiveBoxGeometry.viewRect(for: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                                              imageSize: CGSize(width: 1080, height: 1440),
                                              in: CGSize(width: 390, height: 844))
        XCTAssertEqual(centre.midX, 195, accuracy: 0.01)
        XCTAssertEqual(centre.midY, 422, accuracy: 0.01)
        XCTAssertEqual(centre.width, 316.5, accuracy: 0.01)
    }

    func testAspectFitLetterboxes() {
        let r = LiveBoxGeometry.viewRect(for: CGRect(x: 0, y: 0, width: 1, height: 1),
                                         imageSize: CGSize(width: 400, height: 300),
                                         in: CGSize(width: 200, height: 300), fill: false)
        XCTAssertEqual(r, CGRect(x: 0, y: 75, width: 200, height: 150))
        XCTAssertEqual(LiveBoxGeometry.viewRect(for: .zero, imageSize: .zero, in: CGSize(width: 1, height: 1)), .zero)
    }

    func testSuppressionKeepsTheMostCertainOverlappingBoxPerLabel() {
        let a = det("cat", 0.9, CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4))
        let b = det("cat", 0.6, CGRect(x: 0.12, y: 0.1, width: 0.4, height: 0.4))
        let c = det("dog", 0.5, CGRect(x: 0.12, y: 0.1, width: 0.4, height: 0.4))
        let d = det("cat", 0.7, CGRect(x: 0.6, y: 0.6, width: 0.3, height: 0.3))
        let kept = LiveBoxGeometry.suppress([b, c, a, d])
        XCTAssertEqual(kept.map(\.confidence), [0.9, 0.7, 0.5])
        XCTAssertEqual(LiveBoxGeometry.iou(a.box, d.box), 0)
    }

    // MARK: Throttle

    func testGateDropsFramesWhileOneIsInFlightAndWithinTheInterval() {
        let gate = LiveFrameGate()
        XCTAssertTrue(gate.begin(now: 10, thermal: .nominal))
        XCTAssertFalse(gate.begin(now: 11, thermal: .nominal), "in flight: drop, don't queue")
        gate.finish()
        XCTAssertFalse(gate.begin(now: 10.1, thermal: .nominal), "too soon after the last start")
        XCTAssertTrue(gate.begin(now: 10.25, thermal: .nominal))
        gate.finish()
        XCTAssertEqual(gate.dropped, 2)
    }

    func testGateSlowsWhenWarmAndPausesWhenCritical() {
        let gate = LiveFrameGate()
        XCTAssertTrue(gate.begin(now: 0, thermal: .serious)); gate.finish()
        XCTAssertFalse(gate.begin(now: 0.5, thermal: .serious))
        XCTAssertTrue(gate.begin(now: 1.0, thermal: .serious)); gate.finish()
        XCTAssertFalse(gate.begin(now: 100, thermal: .critical))
        XCTAssertNil(LiveFrameGate.interval(for: .critical))
        let n = LiveFrameGate.interval(for: .nominal)!, f = LiveFrameGate.interval(for: .fair)!
        let s = LiveFrameGate.interval(for: .serious)!
        XCTAssertLessThan(n, f); XCTAssertLessThan(f, s)
    }

    // MARK: Matching by meaning (deterministic: no embedder)

    private let vocab = ["person", "chair", "couch", "bench", "cup", "bottle", "cat", "dog", "laptop",
                         "keyboard", "book", "text", "rectangle", "clock"]

    func testConceptsAnswerQuestionsByMeaningWithoutAnEmbedding() {
        let m = LiveLabelMatcher(embedder: nil)
        XCTAssertFalse(m.usesEmbedding)
        XCTAssertEqual(m.labels(for: "where's something to sit on?", vocabulary: vocab), ["chair", "couch", "bench"])
        XCTAssertEqual(m.labels(for: "anything to drink", vocabulary: vocab), ["cup", "bottle"])
        XCTAssertEqual(m.labels(for: "is there an animal here", vocabulary: vocab), ["cat", "dog"])
        XCTAssertEqual(m.labels(for: "a computer", vocabulary: vocab), ["laptop", "keyboard"])
        XCTAssertEqual(m.labels(for: "my keys", vocabulary: vocab), [])
        XCTAssertEqual(m.labels(for: "", vocabulary: vocab), [])
    }

    func testDirectWordsAndPluralsMatchLabels() {
        let m = LiveLabelMatcher(embedder: nil)
        XCTAssertEqual(m.labels(for: "find the chairs", vocabulary: vocab), ["chair"])
        XCTAssertEqual(m.labels(for: "Where is the wine glass?", vocabulary: ["wine glass", "cup"]), ["wine glass"])
    }

    func testMatchesPickDetectionsAndReadText() {
        let m = LiveLabelMatcher(embedder: nil)
        let found = [det("chair", 0.8), det("cup", 0.9),
                     det("text “EXIT”", 0.7, CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1), .text)]
        XCTAssertEqual(m.matches(question: "something to sit on", in: found, vocabulary: vocab).map(\.label), ["chair"])
        XCTAssertEqual(m.matches(question: "where's the exit", in: found, vocabulary: vocab).map(\.label), ["text “EXIT”"])
        XCTAssertEqual(m.matches(question: "what does the sign say", in: found, vocabulary: vocab).map(\.label), ["text “EXIT”"])
        XCTAssertTrue(m.matches(question: "my keys", in: found, vocabulary: vocab).isEmpty)
    }

    /// Fixed vectors: drives the embedding path deterministically.
    private struct FakeEmbedding: LiveTextEmbedding {
        let table: [String: [Double]]
        func vector(for text: String) -> [Double]? {
            table.first { text.hasPrefix($0.key) }?.value ?? [0, 0, 1]
        }
    }

    func testSemanticMatchesRespectThresholdAndMargin() {
        let fake = FakeEmbedding(table: [
            "a place to rest": [1, 0, 0],
            "chair": [0.9, 0.1, 0], "couch": [0.85, 0.2, 0], "cup": [0.1, 1, 0], "lamp": [0.5, 0.5, 0.7],
            "zzz": [0, 0.01, 1],
        ])
        let m = LiveLabelMatcher(embedder: fake)
        XCTAssertEqual(m.semanticMatches(question: "a place to rest", vocabulary: ["cup", "chair", "couch", "lamp"]),
                       ["chair", "couch"])
        XCTAssertEqual(m.semanticMatches(question: "zzz", vocabulary: ["chair", "cup"]), [],
                       "nothing close enough matches nothing")
        // Words come first, meaning adds the rest without duplicates.
        XCTAssertEqual(m.labels(for: "a place to rest", vocabulary: ["chair", "couch", "bed"]), ["chair", "couch", "bed"])
    }

    func testAppleSentenceEmbeddingFindsDrinksWhenAvailable() throws {
        guard let embedding = NLSentenceTextEmbedding() else { throw XCTSkip("No English sentence embedding here") }
        let m = LiveLabelMatcher(embedder: embedding)
        let drink = m.semanticMatches(question: "anything to drink", vocabulary: vocab)
        XCTAssertTrue(drink.contains("bottle") || drink.contains("cup"), "\(drink)")
        XCTAssertTrue(m.semanticMatches(question: "my keys", vocabulary: vocab).isEmpty)
    }

    // MARK: Words

    func testStatusLines() {
        let found = [det("cup", 0.9), det("chair", 0.6), det("kitchen", 0.5, CGRect(x: 0, y: 0, width: 1, height: 1), .scene)]
        XCTAssertEqual(LiveCameraText.status(question: "", detections: found, matches: [], wanted: [], vocabularyCount: 41),
                       "3 in view: cup, chair, kitchen")
        XCTAssertEqual(LiveCameraText.status(question: "", detections: [], matches: [], wanted: [], vocabularyCount: 41),
                       "Nothing recognised yet")
        XCTAssertEqual(LiveCameraText.status(question: "sit", detections: found, matches: [found[1]],
                                             wanted: ["chair"], vocabularyCount: 41), "Found chair")
        XCTAssertEqual(LiveCameraText.status(question: "sit", detections: [], matches: [],
                                             wanted: ["chair", "couch", "bench"], vocabularyCount: 41),
                       "Looking for chair, couch or bench")
        XCTAssertEqual(LiveCameraText.status(question: "my keys", detections: found, matches: [], wanted: [], vocabularyCount: 41),
                       "Anu can spot 41 kinds of things here, and none of them fits that.")
    }

    func testAskPromptCarriesTheQuestionAndWhatWasFoundMostCertainFirst() {
        let found = [det("kitchen", 0.95, CGRect(x: 0, y: 0, width: 1, height: 1), .scene), det("cat", 0.62), det("person", 0.91)]
        let prompt = LiveCameraText.prompt(question: "  Is the cat asleep? ", detections: found, detectorName: "Apple Vision")
        XCTAssertTrue(prompt.hasPrefix("Is the cat asleep?\n\n("))
        XCTAssertTrue(prompt.contains("Apple Vision found: person 91%, cat 62%, kitchen 95%."), prompt)
        XCTAssertTrue(prompt.contains("go by the picture"))
        let empty = LiveCameraText.prompt(question: "", detections: [], detectorName: "Apple Vision")
        XCTAssertTrue(empty.hasPrefix("What's in this picture?"))
        XCTAssertTrue(empty.contains("found nothing it knows"))
    }

    // MARK: Frames for the chat

    func testFrameEncodesInMemoryAndDownscalesTo1024() throws {
        let big = rectangleImage(size: CGSize(width: 2000, height: 1500), box: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))
        let data = try XCTUnwrap(LiveFrameEncoder.jpeg(big))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1024)
        XCTAssertEqual(image.height, 768)
        let small = rectangleImage(size: CGSize(width: 320, height: 240), box: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))
        let smallData = try XCTUnwrap(LiveFrameEncoder.jpeg(small))
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(smallData as CFData, nil)!, 0, nil)?.width, 320)
    }

    // MARK: Ask Anu reaches the on-device photo path

    @MainActor
    func testAskAnuFrameGoesThroughTheOnDevicePhotoPath() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)", isDirectory: true)
        let orch = AgentOrchestrator(model: ScriptedModel(), sessionsDirectory: dir)
        let frame = try XCTUnwrap(LiveFrameEncoder.jpeg(rectangleImage(box: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))))
        let prompt = LiveCameraText.prompt(question: "What is this?", detections: [det("rectangle", 0.9)],
                                           detectorName: "Apple Vision")
        await orch.run(userMessage: prompt, imageData: frame)
        let user = try XCTUnwrap(orch.messages.first { $0.role == .user })
        XCTAssertEqual(user.imageData, frame)
        XCTAssertTrue(user.content.contains("rectangle 90%"))
        let route = try XCTUnwrap(orch.reasoningSteps.first { $0.action?.hasPrefix("Route →") == true })
        XCTAssertTrue(route.thought.contains("+ image"))
        XCTAssertEqual(route.action, "Route → \(ModelRoute.onDeviceChat.displayName)")
        XCTAssertFalse(orch.isThinking)
    }

    #if os(iOS)
    func testIntentFlagIsOneShot() {
        let defaults = UserDefaults(suiteName: "live-\(UUID().uuidString)")!
        XCTAssertFalse(OpenLiveCameraIntent.consumePending(defaults))
        defaults.set(true, forKey: OpenLiveCameraIntent.pendingKey)
        XCTAssertTrue(OpenLiveCameraIntent.consumePending(defaults))
        XCTAssertFalse(OpenLiveCameraIntent.consumePending(defaults))
    }
    #endif
}
