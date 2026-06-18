import SwiftUI
#if canImport(UIKit) && canImport(AVFoundation)
import UIKit
import AVFoundation

/// Live camera capture for "point-and-ask" Visual Intelligence — the new Siri's
/// Camera mode equivalent. Captures one still and hands back JPEG data; the
/// caller feeds it into the **same** multimodal pipeline a picked photo uses
/// (`orchestrator.run(imageData:)` → the on-device vision model).
///
/// The camera is unavailable in the Simulator; callers should check
/// `CameraCaptureView.isAvailable` and fall back to the photo picker.
struct CameraCaptureView: UIViewControllerRepresentable {
    var onCapture: (Data) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> CameraCaptureController {
        let controller = CameraCaptureController()
        controller.onCapture = onCapture
        controller.onCancel = onCancel
        return controller
    }

    func updateUIViewController(_ controller: CameraCaptureController, context: Context) {}

    /// Whether a usable capture device exists (false in the Simulator).
    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return AVCaptureDevice.default(for: .video) != nil
        #endif
    }
}

/// UIKit controller that owns the capture session, preview, and shutter UI.
final class CameraCaptureController: UIViewController, AVCapturePhotoCaptureDelegate {
    var onCapture: ((Data) -> Void)?
    var onCancel: (() -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let sessionQueue = DispatchQueue(label: "com.anu.camera")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addControls()
        requestAccessThenConfigure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func requestAccessThenConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configureAndStart() } else { self?.onCancel?() }
                }
            }
        default:
            onCancel?() // denied/restricted — bail back to the picker
        }
    }

    private func configureAndStart() {
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            if let device = AVCaptureDevice.default(for: .video),
               let input = try? AVCaptureDeviceInput(device: device),
               self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }

    private func addControls() {
        let shutter = UIButton(type: .system)
        shutter.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 64, weight: .thin)
        shutter.setImage(UIImage(systemName: "circle.circle.fill", withConfiguration: config), for: .normal)
        shutter.tintColor = .white
        shutter.accessibilityLabel = "Capture photo"
        shutter.accessibilityIdentifier = "shutterButton"
        shutter.addTarget(self, action: #selector(capture), for: .touchUpInside)

        let cancel = UIButton(type: .system)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.setTitle("Cancel", for: .normal)
        cancel.tintColor = .white
        cancel.accessibilityIdentifier = "cameraCancelButton"
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        view.addSubview(shutter)
        view.addSubview(cancel)
        NSLayoutConstraint.activate([
            shutter.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutter.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            cancel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            cancel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -36),
        ])
    }

    @objc private func capture() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else {
                DispatchQueue.main.async { self?.onCancel?() }
                return
            }
            self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    @objc private func cancelTapped() { onCancel?() }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        DispatchQueue.main.async { [weak self] in
            if let data { self?.onCapture?(data) } else { self?.onCancel?() }
        }
    }
}
#endif
