import Foundation
import Combine

/// The state of the "Rewrite with Anu" sheet (Android parity row 20). Lives
/// in the app module so it is unit-tested; the action extension compiles it
/// too and only draws it.
@MainActor
final class WritingActionModel: ObservableObject {
    enum Phase: Equatable {
        /// Choosing an action (or typing an instruction).
        case choosing
        case working(String)
        /// A preview; nothing changes in the host until Replace or Copy.
        case preview(text: String, label: String, engine: String)
        /// Left for the Anu app to write.
        case handedOff(label: String)
        /// The extension can't write it itself; the user may hand it to the app.
        case offerHandOff(String)
        case note(String)
    }

    @Published private(set) var original = ""
    @Published private(set) var phase: Phase = .choosing
    @Published var instruction = ""

    /// Apple's on-device engine in this process, or nil.
    let engine: (any WritingEngine)?
    /// Why there's no engine, for the hand-off explanation.
    let engineNote: String
    private let store: WritingHandoffStore?
    private let fits: (WritingPromptSpec) -> Bool
    private let finish: (String?) -> Void
    private var running: Task<Void, Never>?
    /// The request the extension last handed to the app, for its result.
    private var lastSpec: (spec: WritingPromptSpec, label: String)?

    init(engine: (any WritingEngine)?, engineNote: String = "", store: WritingHandoffStore?,
         fits: @escaping (WritingPromptSpec) -> Bool = { _ in true },
         finish: @escaping (String?) -> Void) {
        self.engine = engine
        self.engineNote = engineNote
        self.store = store
        self.fits = fits
        self.finish = finish
    }

    var canHandOff: Bool { store != nil }

    /// The host's selected text. A result the app already wrote for this same
    /// text (an earlier hand-off) comes up as the preview.
    func load(_ text: String) {
        original = text
        if let store, let result = store.result(for: .writingExtension), result.original == text {
            if let edited = result.text {
                phase = .preview(text: edited, label: result.label, engine: result.engine)
            } else {
                phase = .note(result.failure ?? "Anu couldn't do that. Try again.")
            }
            store.consume(result.requestID)
            return
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            phase = .note(WritingInputProblem.empty.message)
        } else if text.count > WritingPrompt.maxChars {
            phase = .note(WritingInputProblem.tooLong(limit: WritingPrompt.maxChars).message)
        } else {
            phase = .choosing
        }
    }

    func run(_ action: WritingAction) {
        start(label: action.label) { try WritingPrompt.request(action, text: self.original) }
    }

    func runInstruction() {
        start(label: "Your instruction") { try WritingPrompt.request(instruction: self.instruction, text: self.original) }
    }

    private func start(label: String, build: () throws -> WritingPromptSpec) {
        running?.cancel()
        let spec: WritingPromptSpec
        do { spec = try build() } catch let problem as WritingInputProblem {
            phase = .note(problem.message); return
        } catch { phase = .note("Anu couldn't do that. Try again."); return }
        lastSpec = (spec, label)
        guard let engine, fits(spec) else {
            // No model in this process: the user decides whether to hand off.
            phase = canHandOff ? .offerHandOff(handOffPrompt) : .note(engineNote)
            return
        }
        phase = .working(label)
        running = Task { [weak self] in
            do {
                let raw = try await engine.write(spec)
                guard !Task.isCancelled, let self else { return }
                if let problem = WritingOutput.problem(raw) {
                    self.phase = .note(problem == "empty result"
                                       ? "Anu didn't come up with anything. Try again."
                                       : "Anu couldn't do that on this device. Try again.")
                } else {
                    self.phase = .preview(text: WritingOutput.clean(raw), label: label, engine: engine.name)
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                let why = "Apple's on-device model couldn't do that here."
                self.phase = self.canHandOff
                    ? .offerHandOff(why + " Anu's app can try it on its own on-device model.")
                    : .note(why)
            }
        }
    }

    /// What the sheet says when the extension can't write it itself.
    var handOffPrompt: String {
        let why = engineNote.isEmpty ? "This is too long for Apple's on-device model." : engineNote
        return "\(why) Anu's app can write it on its own on-device model: tap Hand to Anu, then open Anu."
    }

    /// Leaves the last request for the app (the user tapped Hand to Anu).
    func handOff() {
        guard let store, let last = lastSpec else { return }
        store.submit(WritingHandoffRequest(source: .writingExtension, label: last.label,
                                           spec: last.spec, original: original))
        phase = .handedOff(label: last.label)
    }

    func back() {
        running?.cancel()
        phase = .choosing
    }

    /// The previewed text, for Replace and Copy.
    var previewText: String? {
        if case .preview(let text, _, _) = phase { return text }
        return nil
    }

    func replace() {
        guard let text = previewText else { return }
        finish(text)
    }

    func close() {
        running?.cancel()
        finish(nil)
    }
}
