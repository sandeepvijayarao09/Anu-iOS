import Foundation

// The hand-off between the writing extensions and the app (Android parity rows
// 20–21). An extension can't load Gemma (an action extension gets roughly
// 120 MB, a keyboard much less). When Apple's on-device model isn't available
// in the extension, it leaves the built request in the App Group; the app runs
// it on its own on-device model the next time it's opened, and leaves the
// result for the extension to preview. Nothing here touches the network.
//
// The text is personal, so the store keeps as little as it can: one pending
// request and one result per source, each dropped after `lifetime`, and a
// result is deleted once it's used or discarded.

enum WritingHandoffSource: String, Codable, Sendable, CaseIterable {
    case writingExtension
    case keyboard

    var label: String {
        switch self {
        case .writingExtension: return "Rewrite with Anu"
        case .keyboard: return "Anu Keyboard"
        }
    }
}

struct WritingHandoffRequest: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    let source: WritingHandoffSource
    /// The action's label, for the app's sheet and the extension's preview.
    let label: String
    let spec: WritingPromptSpec
    /// The text the result is made from. The extension checks it is still
    /// what the host holds before it replaces anything.
    let original: String
    /// Small extension-specific facts the extension needs to place the result
    /// (the keyboard's edit mode). Never text beyond `original`.
    let meta: [String: String]
    let createdAt: Date

    init(id: UUID = UUID(), source: WritingHandoffSource, label: String, spec: WritingPromptSpec,
         original: String, meta: [String: String] = [:], createdAt: Date = Date()) {
        self.id = id
        self.source = source
        self.label = label
        self.spec = spec
        self.original = original
        self.meta = meta
        self.createdAt = createdAt
    }
}

struct WritingHandoffResult: Codable, Sendable, Identifiable, Equatable {
    var id: UUID { requestID }
    let requestID: UUID
    let source: WritingHandoffSource
    let label: String
    let original: String
    let meta: [String: String]
    /// The cleaned edit, or nil when the model failed (then `failure` says why).
    let text: String?
    let failure: String?
    /// Which on-device model wrote it.
    let engine: String
    let createdAt: Date

    init(request: WritingHandoffRequest, text: String?, failure: String?, engine: String, createdAt: Date = Date()) {
        self.requestID = request.id
        self.source = request.source
        self.label = request.label
        self.original = request.original
        self.meta = request.meta
        self.text = text
        self.failure = failure
        self.engine = engine
        self.createdAt = createdAt
    }
}

struct WritingHandoffState: Codable, Equatable {
    var pending: [WritingHandoffRequest] = []
    var results: [WritingHandoffResult] = []
}

/// The App Group file the extensions and the app share for hand-offs.
struct WritingHandoffStore {
    /// How long a request or result is kept before it's dropped unread.
    static let lifetime: TimeInterval = 15 * 60
    static let fileName = "writing-handoff.json"

    private let file: AppGroupFile<WritingHandoffState>
    private let now: () -> Date

    init(directory: URL = AppGroup.containerURL, now: @escaping () -> Date = Date.init) {
        self.file = AppGroupFile(Self.fileName, directory: directory)
        self.now = now
    }

    /// Leaves a request for the app. A newer request from the same source
    /// replaces the older one, and any old result from that source goes.
    func submit(_ request: WritingHandoffRequest) {
        var state = fresh()
        state.pending.removeAll { $0.source == request.source }
        state.results.removeAll { $0.source == request.source }
        state.pending.append(request)
        save(state)
    }

    /// The requests waiting for the app, removed from the store.
    func takePending() -> [WritingHandoffRequest] {
        var state = fresh()
        let pending = state.pending
        state.pending = []
        save(state)
        return pending
    }

    var hasPending: Bool { !fresh().pending.isEmpty }

    func isPending(_ source: WritingHandoffSource) -> Bool {
        fresh().pending.contains { $0.source == source }
    }

    /// Leaves a result for the extension; replaces any older one from its source.
    func post(_ result: WritingHandoffResult) {
        var state = fresh()
        state.results.removeAll { $0.source == result.source }
        state.results.append(result)
        save(state)
    }

    /// The newest result for `source`, if it hasn't expired. Read-only.
    func result(for source: WritingHandoffSource) -> WritingHandoffResult? {
        fresh().results.last { $0.source == source }
    }

    /// Deletes the result once it's used or discarded.
    func consume(_ requestID: UUID) {
        var state = fresh()
        state.results.removeAll { $0.requestID == requestID }
        save(state)
    }

    /// Drops everything from `source` (a cancelled hand-off).
    func clear(_ source: WritingHandoffSource) {
        var state = fresh()
        state.pending.removeAll { $0.source == source }
        state.results.removeAll { $0.source == source }
        save(state)
    }

    /// The stored state with expired entries gone.
    private func fresh() -> WritingHandoffState {
        var state = file.load() ?? WritingHandoffState()
        let cutoff = now().addingTimeInterval(-Self.lifetime)
        let before = state
        state.pending.removeAll { $0.createdAt < cutoff }
        state.results.removeAll { $0.createdAt < cutoff }
        if state != before { save(state) }
        return state
    }

    private func save(_ state: WritingHandoffState) {
        if state.pending.isEmpty && state.results.isEmpty {
            file.clear()
        } else {
            file.save(state)
        }
    }
}
