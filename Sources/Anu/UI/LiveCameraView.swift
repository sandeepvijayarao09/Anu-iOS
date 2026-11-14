import SwiftUI
#if os(iOS)
import AVFoundation
import CoreImage
import UIKit

/// Live camera (Android parity row 22): the back camera full screen with a
/// white box and label round each thing Apple Vision finds, a search field
/// matched by meaning, and "Ask Anu about this", which freezes the frame and
/// sends it into the chat through the ordinary on-device photo path.
///
/// Privacy: frames live in memory only — the newest one, for freezing. None is
/// saved, logged or sent; nothing here touches the network, so there is no
/// ledger entry. A frame reaches disk only if the user sends it into the
/// chat, and then as that message's photo (SecureFile, like any photo).
struct LiveCameraView: View {
    /// JPEG (≤ 1024 px, in memory) and the full chat message.
    var onAsk: (Data, String) -> Void
    var onClose: () -> Void

    @StateObject private var model = LiveCameraModel()
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let frozen = model.frozen {
                Image(decorative: frozen, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
            } else {
                LiveCameraPreview(session: model.session).ignoresSafeArea()
            }
            boxes.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Spacer()
                panel
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            model.start()
            UIApplication.shared.isIdleTimerDisabled = true   // a viewfinder stays on
        }
        .onDisappear {
            model.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: Boxes

    private var boxes: some View {
        GeometryReader { geo in
            let matching = Set(model.matches.map(\.id))
            let searching = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
            ForEach(model.detections.filter { $0.source != .scene }) { d in
                let r = LiveBoxGeometry.viewRect(for: d.box, imageSize: model.imageSize, in: geo.size)
                let hit = matching.contains(d.id)
                let dim = searching && !hit
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(dim ? 0.35 : 1), lineWidth: hit ? 4 : 2)
                    Text(d.caption)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(hit ? Color.black : Color.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(hit ? Color.white : Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .opacity(dim ? 0.5 : 1)
                        .offset(x: 0, y: -22)
                }
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(model.statusLine)
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(alignment: .top) {
            Button(action: onClose) {
                Label("Chat", systemImage: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            .accessibilityIdentifier("liveCameraClose")
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Label("On this phone · nothing saved", systemImage: "lock.fill")
                    .font(.caption)
                Text(model.detectorLine)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notice = model.notice {
                Text(notice).font(.footnote).foregroundStyle(.yellow)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(model.frozen == nil ? "Find something, like “something to sit on”" : "Ask about this frame",
                          text: $model.query)
                    .focused($searchFocused)
                    .submitLabel(model.frozen == nil ? .search : .send)
                    .onSubmit { if model.frozen != nil { send() } }
                    .accessibilityIdentifier("liveCameraQuery")
            }
            .padding(10)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            Text(model.statusLine)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityIdentifier("liveCameraStatus")

            if model.frozen == nil {
                Button {
                    model.freeze()
                    searchFocused = true
                } label: {
                    Label("Ask Anu about this", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white).foregroundStyle(.black)
                .disabled(!model.hasFrame)
                .accessibilityIdentifier("liveCameraAsk")
            } else {
                HStack {
                    Button("Back to live") { model.unfreeze() }
                        .buttonStyle(.bordered).tint(.white)
                    Button { send() } label: {
                        Label("Send to Anu", systemImage: "arrow.up.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white).foregroundStyle(.black)
                    .accessibilityIdentifier("liveCameraSend")
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private func send() {
        guard let (data, prompt) = model.askPayload() else { return }
        onAsk(data, prompt)
    }
}

// MARK: - Model

@MainActor
final class LiveCameraModel: NSObject, ObservableObject {
    @Published var detections: [LiveDetection] = []
    @Published var query = "" { didSet { rematch() } }
    @Published private(set) var matches: [LiveDetection] = []
    @Published private(set) var statusLine = "Starting the camera…"
    @Published private(set) var detectorLine = ""
    @Published private(set) var frozen: CGImage?
    @Published private(set) var imageSize = CGSize(width: 3, height: 4)
    @Published private(set) var notice: String?
    @Published private(set) var hasFrame = false

    let session = AVCaptureSession()
    nonisolated(unsafe) private let detector: LiveObjectDetecting = LiveDetectorFactory.make()
    private let matcher = LiveLabelMatcher()
    nonisolated private let gate = LiveFrameGate()
    private let videoQueue = DispatchQueue(label: "com.anu.livecamera.frames", qos: .userInitiated)
    nonisolated(unsafe) private let context = CIContext(options: [.cacheIntermediates: false])
    /// The newest processed frame (memory only), for "Ask Anu". Touched on videoQueue.
    nonisolated(unsafe) private var latest: CGImage?
    private var configured = false
    private var frozenDetections: [LiveDetection] = []
    private var thermalObserver: NSObjectProtocol?
    private var lastStamp: CFTimeInterval = 0
    private var fps: Double = 0

    func start() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.updateThermalNotice() } }
        updateThermalNotice()
        detectorLine = "\(detector.name) · starting"
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor [weak self] in
                    if granted { self?.configureAndRun() } else { self?.denied() }
                }
            }
        default: denied()
        }
    }

    func stop() {
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
        let session = self.session
        videoQueue.async { [weak self] in
            if session.isRunning { session.stopRunning() }
            self?.latest = nil   // let the last frame go with the screen
        }
    }

    private func denied() {
        statusLine = "Camera access is off. Turn it on in Settings → Anu → Camera."
    }

    private func configureAndRun() {
        guard !configured else { videoQueue.async { [session] in session.startRunning() }; return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            statusLine = "No camera on this device."
            detectorLine = detector.name
            return
        }
        configured = true
        let output = AVCaptureVideoDataOutput()
        // Drop late frames instead of queueing them; the gate drops more.
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        let session = self.session
        videoQueue.async {
            session.beginConfiguration()
            session.sessionPreset = .high
            if session.canAddInput(input) { session.addInput(input) }
            if session.canAddOutput(output) { session.addOutput(output) }
            if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90   // portrait buffers, so boxes need no rotation
            }
            session.commitConfiguration()
            session.startRunning()
        }
        statusLine = "Looking…"
    }

    private func updateThermalNotice() {
        switch ProcessInfo.processInfo.thermalState {
        case .critical: notice = "Detection is paused while the phone cools down."
        case .serious: notice = "The phone is warm, so detection has slowed."
        default: notice = nil
        }
    }

    fileprivate func publish(_ found: [LiveDetection], size: CGSize, ms: Double) {
        guard frozen == nil else { return }
        let now = CACurrentMediaTime()
        if lastStamp > 0 { fps = fps == 0 ? 1 / (now - lastStamp) : fps * 0.8 + 0.2 / (now - lastStamp) }
        lastStamp = now
        detections = found
        imageSize = size
        hasFrame = true
        detectorLine = String(format: "%@ · %.0f fps · %.0f ms", detector.name, fps, ms)
        rematch()
    }

    private func rematch() {
        let wanted = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? [] : matcher.labels(for: query, vocabulary: detector.vocabulary)
        matches = wanted.isEmpty && query.isEmpty
            ? [] : matcher.matches(question: query, in: detections, vocabulary: detector.vocabulary)
        statusLine = frozen != nil
            ? "Frozen. Ask a question, then send it to Anu."
            : LiveCameraText.status(question: query, detections: detections, matches: matches,
                                    wanted: wanted, vocabularyCount: detector.vocabulary.count)
    }

    func freeze() {
        // Read the newest frame on the video queue to avoid racing the delegate.
        let image = videoQueue.sync { latest }
        guard let image else { return }
        frozen = image
        frozenDetections = detections
        imageSize = CGSize(width: image.width, height: image.height)
        rematch()
    }

    func unfreeze() {
        frozen = nil
        frozenDetections = []
        rematch()
    }

    /// The frame as an in-memory JPEG and the chat message with the labels.
    func askPayload() -> (Data, String)? {
        guard let frozen, let data = LiveFrameEncoder.jpeg(frozen) else { return nil }
        return (data, LiveCameraText.prompt(question: query, detections: frozenDetections, detectorName: detector.name))
    }

    // Runs on videoQueue.
    nonisolated fileprivate func handle(_ buffer: CVPixelBuffer) {
        let thermal = ProcessInfo.processInfo.thermalState
        guard gate.begin(now: CACurrentMediaTime(), thermal: thermal) else { return }
        defer { gate.finish() }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let image = context.createCGImage(ci, from: ci.extent) else { return }
        latest = image
        let t0 = CACurrentMediaTime()
        let found = (try? detector.detect(in: image)) ?? []
        let ms = (CACurrentMediaTime() - t0) * 1000
        let size = CGSize(width: image.width, height: image.height)
        Task { @MainActor [weak self] in self?.publish(found, size: size, ms: ms) }
    }
}

extension LiveCameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        handle(buffer)
    }
}

// MARK: - Preview layer

struct LiveCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer } // swiftlint:disable:this force_cast (layerClass above guarantees it)
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}
#endif
