import Foundation
import Combine
import os

// MARK: - Download storage (pure, testable)
//
// Where downloaded `.litertlm` models live on disk and how we decide a model is
// "present". Application Support (not Documents) so the multi-GB blobs are
// app-internal, not surfaced in Files/iCloud. Injectable `directory` so tests
// run against a temp dir — same pattern as `SessionStore`.

struct ModelDownloadStore: Sendable {
    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("Models", isDirectory: true)
        }
    }

    /// Final resting path for a model — `<dir>/<modelFile>`. The HF `resolve`
    /// URL's last path component equals `modelFile`, so the download delegate
    /// can reconstruct this same destination without main-actor state.
    func fileURL(for model: AllowlistModel) -> URL {
        directory.appendingPathComponent(model.modelFile)
    }

    func fileSize(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
        return size
    }

    /// Present when the file exists and is at least ~the expected size. Exact
    /// byte-match is too brittle (HF can serve a slightly different count than
    /// the manifest records); a partial/temp file is meaningfully smaller, so
    /// "≥ 99% of expected" cleanly separates complete from interrupted.
    func isDownloaded(_ model: AllowlistModel) -> Bool {
        guard let size = fileSize(at: fileURL(for: model)) else { return false }
        return size >= Int64(Double(model.sizeInBytes) * 0.99)
    }

    func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func delete(_ model: AllowlistModel) {
        try? FileManager.default.removeItem(at: fileURL(for: model))
    }
}

// MARK: - Download manager
//
// Drives Hugging Face downloads of `.litertlm` models, mirroring Google AI Edge
// Gallery's flow: fetch the blob the allowlist pins (repo + commit), show
// progress, store it, then hand the path to the LiteRT engine. Delegate-based
// `URLSession` so we get byte-level progress, cancellation with resume data,
// and proper error surfacing. (Background-session continuation across app
// suspension is the natural next step; foreground is correct and resumable.)

@MainActor
final class ModelDownloadManager: NSObject, ObservableObject {
    static let shared = ModelDownloadManager()

    enum State: Equatable {
        case notDownloaded
        case downloading(progress: Double)   // 0...1, or < 0 when indeterminate
        case downloaded
        case failed(String)
    }

    @Published private(set) var states: [String: State] = [:]

    /// HF access token for gated `google/*` repos. Stored in UserDefaults; a
    /// change republishes so gated rows re-enable their Download button.
    static let tokenKey = "huggingface_token"
    var huggingFaceToken: String? {
        get {
            let t = UserDefaults.standard.string(forKey: Self.tokenKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty == false) ? t : nil
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                UserDefaults.standard.set(trimmed, forKey: Self.tokenKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.tokenKey)
            }
            objectWillChange.send()
        }
    }

    let allModels: [AllowlistModel]
    private nonisolated let store: ModelDownloadStore
    private static let log = Logger(subsystem: "com.anu.app", category: "ModelDownload")

    // URLSession retains its delegate (self); fine for the `.shared` singleton.
    // Lazy so tests that only inspect on-disk state never create it.
    private lazy var session: URLSession =
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    private var tasks: [String: URLSessionDownloadTask] = [:]   // modelId -> task
    private var taskToModelID: [Int: String] = [:]              // taskIdentifier -> modelId
    private var resumeData: [String: Data] = [:]                // modelId -> resume blob

    init(store: ModelDownloadStore = ModelDownloadStore(),
         allowlist: ModelAllowlist = .bundled) {
        self.store = store
        self.allModels = allowlist.models
        super.init()
        refreshStatesFromDisk()
    }

    // MARK: Queries

    func state(for model: AllowlistModel) -> State { states[model.id] ?? .notDownloaded }

    func model(id: String) -> AllowlistModel? { allModels.first { $0.id == id } }

    func fileURL(for model: AllowlistModel) -> URL { store.fileURL(for: model) }

    /// Reconcile published state with what's actually on disk (called at launch
    /// and after delete). Never clobbers an in-flight download.
    func refreshStatesFromDisk() {
        for m in allModels {
            if case .downloading = states[m.id] { continue }
            states[m.id] = store.isDownloaded(m) ? .downloaded : .notDownloaded
        }
    }

    // MARK: Actions

    func download(_ model: AllowlistModel) {
        if store.isDownloaded(model) { states[model.id] = .downloaded; return }
        if tasks[model.id] != nil { return }   // already downloading
        if model.requiresAuth && huggingFaceToken == nil {
            states[model.id] = .failed("Gated Google model — add a Hugging Face token below and accept the license on huggingface.co.")
            return
        }
        guard let url = model.downloadURL else {
            states[model.id] = .failed("Invalid download URL")
            return
        }

        states[model.id] = .downloading(progress: 0)
        let task: URLSessionDownloadTask
        if let data = resumeData.removeValue(forKey: model.id) {
            task = session.downloadTask(withResumeData: data)
        } else {
            var request = URLRequest(url: url)
            if model.requiresAuth, let token = huggingFaceToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            task = session.downloadTask(with: request)
        }
        tasks[model.id] = task
        taskToModelID[task.taskIdentifier] = model.id
        task.resume()
    }

    /// Cancel, keeping resume data so Download picks up where it left off.
    func cancel(_ model: AllowlistModel) {
        guard let task = tasks[model.id] else { return }
        task.cancel(byProducingResumeData: { [weak self] data in
            guard let data else { return }
            Task { @MainActor in self?.resumeData[model.id] = data }
        })
        // didCompleteWithError(cancelled) will reconcile state.
    }

    func delete(_ model: AllowlistModel) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        resumeData[model.id] = nil
        store.delete(model)
        states[model.id] = .notDownloaded
    }

    // MARK: Delegate → main-actor reducers

    private func cleanupTask(_ taskIdentifier: Int, modelID: String) {
        tasks[modelID] = nil
        taskToModelID[taskIdentifier] = nil
    }

    fileprivate func reportProgress(taskIdentifier: Int, progress: Double) {
        guard let id = taskToModelID[taskIdentifier] else { return }
        if case .downloaded = states[id] { return }
        states[id] = .downloading(progress: progress < 0 ? -1 : min(1, progress))
    }

    fileprivate func reportFinished(taskIdentifier: Int, failure: String?) {
        guard let id = taskToModelID[taskIdentifier], let model = model(id: id) else { return }
        cleanupTask(taskIdentifier, modelID: id)
        if let failure {
            states[id] = .failed(failure)
        } else if store.isDownloaded(model) {
            states[id] = .downloaded
        } else {
            states[id] = .failed("Downloaded file is incomplete — try again.")
        }
    }

    fileprivate func reportError(taskIdentifier: Int, message: String?, resume: Data?) {
        guard let id = taskToModelID[taskIdentifier], let model = model(id: id) else { return }
        if let resume { resumeData[id] = resume }
        cleanupTask(taskIdentifier, modelID: id)
        if let message {
            states[id] = .failed(message)
        } else {
            // Cancelled: downloaded if a prior attempt completed, else idle.
            states[id] = store.isDownloaded(model) ? .downloaded : .notDownloaded
        }
    }

    /// Human-readable reason for a non-2xx HTTP response.
    fileprivate nonisolated static func httpFailureMessage(_ status: Int) -> String {
        switch status {
        case 401: return "Unauthorized — your Hugging Face token is missing or invalid."
        case 403: return "Forbidden — accept the model license on huggingface.co, then retry."
        case 404: return "Not found — the model file moved. Update the allowlist."
        default:  return "Download failed (HTTP \(status))."
        }
    }

    /// Where the delegate moves a finished download. Reconstructed from the
    /// original request URL so it works off the main actor.
    fileprivate nonisolated func destination(forFileName name: String) -> URL {
        store.directory.appendingPathComponent(name)
    }

    fileprivate nonisolated func ensureModelsDirectory() {
        try? store.ensureDirectory()
    }
}

// MARK: - URLSessionDownloadDelegate
//
// Called off the main actor (delegateQueue: nil). The temp file in
// `didFinishDownloadingTo` must be consumed before the method returns, so the
// move happens here synchronously; only state mutation hops to the main actor.

extension ModelDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : -1
        Task { @MainActor in self.reportProgress(taskIdentifier: id, progress: progress) }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            let msg = Self.httpFailureMessage(http.statusCode)
            Task { @MainActor in self.reportFinished(taskIdentifier: id, failure: msg) }
            return
        }

        guard let fileName = downloadTask.originalRequest?.url?.lastPathComponent
                ?? downloadTask.currentRequest?.url?.lastPathComponent else {
            Task { @MainActor in self.reportFinished(taskIdentifier: id, failure: "Missing download URL") }
            return
        }

        ensureModelsDirectory()
        var dest = destination(forFileName: fileName)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            // Multi-GB models must not balloon the user's iCloud backup.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dest.setResourceValues(values)
            Task { @MainActor in self.reportFinished(taskIdentifier: id, failure: nil) }
        } catch {
            let msg = error.localizedDescription
            Task { @MainActor in self.reportFinished(taskIdentifier: id, failure: msg) }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }   // success path handled above
        let id = task.taskIdentifier
        let nsError = error as NSError
        let resume = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let cancelled = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        let message: String? = cancelled ? nil : error.localizedDescription
        Task { @MainActor in self.reportError(taskIdentifier: id, message: message, resume: resume) }
    }
}
