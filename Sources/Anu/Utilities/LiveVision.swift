import Foundation
import CoreGraphics
import ImageIO
import Vision
#if canImport(CoreML)
import CoreML
#endif

// Live camera's detection layer (Android parity row 22, ADR-111 adapted).
//
// Everything here is pure logic or Apple's on-device Vision framework, so it
// runs (and is unit tested) on still images without a camera. No frame ever
// leaves the device, is logged, or is written to disk from this file.

// MARK: - Detections

/// One thing found in a frame.
struct LiveDetection: Equatable, Identifiable, Sendable {
    /// What found it. `scene` labels describe the whole frame and carry no
    /// meaningful box (it is the full frame), so the overlay doesn't draw them.
    enum Source: String, Sendable { case animal, person, face, rectangle, text, scene, model }

    var id: String { "\(source.rawValue):\(label):\(Int(box.midX * 100)),\(Int(box.midY * 100))" }
    /// Lower-case display name ("cat", "person", "text “EXIT”").
    let label: String
    /// 0...1.
    let confidence: Float
    /// Normalized to the oriented image, **top-left origin** (UIKit-style).
    let box: CGRect
    let source: Source

    /// "cat 91%".
    var caption: String { "\(label) \(Int((confidence * 100).rounded()))%" }
    /// The vocabulary word the matcher compares against ("text" for any text).
    var matchKey: String { source == .text ? "text" : label }
}

/// Swappable detector: Apple's Vision today, an optional Core ML detector
/// (e.g. YOLOX-Nano with an NMS pipeline) behind the same seam.
protocol LiveObjectDetecting: AnyObject {
    /// Short name for the status line ("Apple Vision").
    var name: String { get }
    /// Every label this detector can produce; the "by meaning" matcher
    /// searches this so it can say "none of them fits that".
    var vocabulary: [String] { get }
    /// Detects in an already-oriented image. Called off the main thread.
    func detect(in image: CGImage) throws -> [LiveDetection]
}

// MARK: - Box geometry

enum LiveBoxGeometry {
    /// Vision's normalized rect (bottom-left origin) → top-left origin.
    static func topLeft(fromVision r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    /// Maps a normalized top-left box in an image of `imageSize` onto a view of
    /// `viewSize` showing that image with aspect *fill* (the camera preview's
    /// `.resizeAspectFill`) or aspect *fit* (the frozen still).
    static func viewRect(for box: CGRect, imageSize: CGSize, in viewSize: CGSize, fill: Bool = true) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let sx = viewSize.width / imageSize.width
        let sy = viewSize.height / imageSize.height
        let scale = fill ? max(sx, sy) : min(sx, sy)
        let shown = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let ox = (viewSize.width - shown.width) / 2
        let oy = (viewSize.height - shown.height) / 2
        return CGRect(x: ox + box.minX * shown.width,
                      y: oy + box.minY * shown.height,
                      width: box.width * shown.width,
                      height: box.height * shown.height)
    }

    /// Intersection over union of two rects.
    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = i.width * i.height
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }

    /// Greedy non-maximum suppression per label: keeps the most certain box
    /// and drops same-label boxes overlapping it by more than `threshold`.
    static func suppress(_ detections: [LiveDetection], iouThreshold threshold: CGFloat = 0.5) -> [LiveDetection] {
        var kept: [LiveDetection] = []
        for d in detections.sorted(by: { $0.confidence > $1.confidence }) {
            if kept.contains(where: { $0.label == d.label && iou($0.box, d.box) > threshold }) { continue }
            kept.append(d)
        }
        return kept
    }
}

// MARK: - Frame throttle

/// Throttles frame processing and **drops** frames rather than queueing them:
/// a frame is taken only if none is in flight and enough time has passed for
/// the current thermal state. At `.critical` detection pauses entirely.
final class LiveFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = false
    private var lastStart: TimeInterval = -.infinity
    private(set) var dropped = 0

    /// Seconds between processed frames for a thermal state; nil = paused.
    static func interval(for thermal: ProcessInfo.ThermalState) -> TimeInterval? {
        switch thermal {
        case .nominal: return 0.2      // ≤ 5 fps of detection
        case .fair: return 0.33        // ≤ 3 fps
        case .serious: return 1.0      // ≤ 1 fps
        case .critical: return nil     // paused
        @unknown default: return 1.0
        }
    }

    /// True when the caller should process this frame now (and must later
    /// call `finish()`); false means drop it.
    func begin(now: TimeInterval, thermal: ProcessInfo.ThermalState) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !inFlight, let gap = Self.interval(for: thermal), now - lastStart >= gap else {
            dropped += 1
            return false
        }
        inFlight = true
        lastStart = now
        return true
    }

    func finish() {
        lock.lock(); inFlight = false; lock.unlock()
    }
}

// MARK: - Apple Vision detector

/// Boxes from Apple's built-in Vision requests — no model download:
/// animals (cats, dogs), people, faces, rectangles (screens, papers, signs)
/// and text, plus a few whole-frame scene labels for context.
final class VisionLiveDetector: LiveObjectDetecting {
    let name = "Apple Vision"
    /// Run the (heavier) scene classifier on every Nth detection.
    var sceneEvery = 3
    var minimumSceneConfidence: Float = 0.35
    var includeText = true
    private var calls = 0

    /// Scene labels Vision's classifier knows and the matcher should search.
    /// Kept to everyday things; the classifier itself knows ~1,300 labels.
    static let sceneVocabulary = [
        "chair", "sofa", "bench", "bed", "table", "desk", "cup", "bottle", "glass", "wine",
        "food", "fruit", "plant", "flower", "book", "computer", "laptop", "keyboard",
        "phone", "television", "screen", "car", "bicycle", "door", "window", "stairs",
        "kitchen", "bag", "shoe", "clock", "lamp", "toy", "tree", "sky", "building",
    ]

    var vocabulary: [String] {
        ["cat", "dog", "person", "face", "rectangle", "text"] + Self.sceneVocabulary
    }

    func detect(in image: CGImage) throws -> [LiveDetection] {
        calls += 1
        let animals = VNRecognizeAnimalsRequest()
        let humans = VNDetectHumanRectanglesRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let rects = VNDetectRectanglesRequest()
        rects.maximumObservations = 4
        rects.minimumConfidence = 0.6
        rects.minimumSize = 0.1
        var requests: [VNRequest] = [animals, humans, faces, rects]
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false
        if includeText { requests.append(text) }
        let scene = VNClassifyImageRequest()
        let runScene = sceneEvery > 0 && (calls - 1) % sceneEvery == 0
        if runScene { requests.append(scene) }

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        // Each request can fail on its own (e.g. a missing model in a
        // simulator); a failed request just contributes nothing.
        for request in requests { try? handler.perform([request]) }

        var out: [LiveDetection] = []
        for o in animals.results ?? [] {
            guard let top = o.labels.first else { continue }
            out.append(LiveDetection(label: top.identifier.lowercased(), confidence: top.confidence,
                                     box: LiveBoxGeometry.topLeft(fromVision: o.boundingBox), source: .animal))
        }
        for o in humans.results ?? [] {
            out.append(LiveDetection(label: "person", confidence: o.confidence,
                                     box: LiveBoxGeometry.topLeft(fromVision: o.boundingBox), source: .person))
        }
        for o in faces.results ?? [] {
            out.append(LiveDetection(label: "face", confidence: o.confidence,
                                     box: LiveBoxGeometry.topLeft(fromVision: o.boundingBox), source: .face))
        }
        for o in rects.results ?? [] {
            out.append(LiveDetection(label: "rectangle", confidence: o.confidence,
                                     box: LiveBoxGeometry.topLeft(fromVision: o.boundingBox), source: .rectangle))
        }
        if includeText {
            for o in (text.results ?? []).prefix(6) {
                guard let c = o.topCandidates(1).first, c.confidence >= 0.3 else { continue }
                let snippet = String(c.string.prefix(24))
                out.append(LiveDetection(label: "text “\(snippet)”", confidence: c.confidence,
                                         box: LiveBoxGeometry.topLeft(fromVision: o.boundingBox), source: .text))
            }
        }
        if runScene {
            lastScene = Self.sceneLabels(from: scene.results ?? [], minimum: minimumSceneConfidence)
        }
        return LiveBoxGeometry.suppress(out) + lastScene
    }

    /// Scene labels persist between the frames where the classifier runs.
    private var lastScene: [LiveDetection] = []

    static func sceneLabels(from results: [VNClassificationObservation], minimum: Float) -> [LiveDetection] {
        results
            .filter { $0.confidence >= minimum }
            .prefix(3)
            .map { LiveDetection(label: $0.identifier.replacingOccurrences(of: "_", with: " ").lowercased(),
                                 confidence: $0.confidence,
                                 box: CGRect(x: 0, y: 0, width: 1, height: 1), source: .scene) }
    }
}

// MARK: - Optional Core ML detector (seam)

#if canImport(CoreML)
/// Optional Core ML object detector behind the same seam — for example
/// YOLOX-Nano (Megvii, Apache 2.0) exported to Core ML **with an NMS
/// pipeline**, so Vision returns `VNRecognizedObjectObservation`s.
///
/// No model ships with Anu: converting YOLOX needs its PyTorch checkpoint
/// and coremltools (the ONNX frontend is gone), which wasn't done here.
/// Drop a compiled `LiveDetector.mlmodelc` into the app bundle and
/// `LiveDetectorFactory` picks it up; otherwise Apple Vision is used.
final class CoreMLLiveDetector: LiveObjectDetecting {
    let name: String
    let vocabulary: [String]
    private let request: VNCoreMLRequest
    var minimumConfidence: Float = 0.4

    init(model: MLModel, name: String, vocabulary: [String]) throws {
        let vnModel = try VNCoreMLModel(for: model)
        request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .scaleFit
        self.name = name
        self.vocabulary = vocabulary
    }

    func detect(in image: CGImage) throws -> [LiveDetection] {
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        let found = (request.results as? [VNRecognizedObjectObservation] ?? []).compactMap { o -> LiveDetection? in
            guard let top = o.labels.first, top.confidence >= minimumConfidence else { return nil }
            return LiveDetection(label: LiveDetectorFactory.friendlyLabel(top.identifier), confidence: top.confidence,
                                 box: LiveBoxGeometry.topLeft(fromVision: o.boundingBox), source: .model)
        }
        return LiveBoxGeometry.suppress(found)
    }
}
#endif

enum LiveDetectorFactory {
    /// The 80 COCO labels, used when a model doesn't list its own.
    static let cocoLabels = [
        "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
        "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat",
        "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack",
        "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball",
        "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket",
        "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
        "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair",
        "couch", "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse",
        "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink",
        "refrigerator", "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush",
    ]

    /// Darknet's spellings in Apple's YOLOv3 Tiny, mapped to the COCO names the
    /// label matcher and the chat use ("something to sit on" must find a sofa).
    static let darknetNames: [String: String] = [
        "motorbike": "motorcycle", "aeroplane": "airplane", "sofa": "couch",
        "pottedplant": "potted plant", "diningtable": "dining table", "tvmonitor": "tv",
    ]

    static func friendlyLabel(_ identifier: String) -> String {
        let label = identifier.lowercased()
        return darknetNames[label] ?? label
    }

    /// A bundled Core ML detector when present, else Apple Vision. The app
    /// ships Apple's YOLOv3 Tiny (80 COCO objects; Core ML model gallery,
    /// Darknet licence) as LiveDetector.mlmodelc; its labels and name come
    /// from the model itself.
    static func make(bundle: Bundle = .main) -> LiveObjectDetecting {
        #if canImport(CoreML)
        if let url = bundle.url(forResource: "LiveDetector", withExtension: "mlmodelc"),
           let model = try? MLModel(contentsOf: url) {
            let description = model.modelDescription
            let labels = (description.classLabels as? [String])?.map(friendlyLabel) ?? cocoLabels
            let version = description.metadata[.versionString] as? String
            let name = (version?.isEmpty == false ? version! : "Core ML detector")
                .replacingOccurrences(of: "YOLOv3-tiny", with: "YOLOv3 Tiny")
            if let detector = try? CoreMLLiveDetector(model: model, name: name, vocabulary: labels) {
                return detector
            }
        }
        #endif
        return VisionLiveDetector()
    }
}

// MARK: - Frames for the chat

enum LiveFrameEncoder {
    /// Downscales to at most `maxSide` pixels on the longer side and encodes
    /// JPEG in memory (never a file) for the chat's photo path.
    static func jpeg(_ image: CGImage, maxSide: Int = 1024, quality: CGFloat = 0.8) -> Data? {
        let longer = max(image.width, image.height)
        var source = image
        if longer > maxSide {
            let scale = CGFloat(maxSide) / CGFloat(longer)
            let w = max(1, Int(CGFloat(image.width) * scale)), h = max(1, Int(CGFloat(image.height) * scale))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { return nil }
            source = scaled
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, source, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
