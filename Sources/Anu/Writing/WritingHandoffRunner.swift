import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Runs a writing task on one of the app's on-device models (Gemma through
/// LiteRT-LM, or the scripted model in tests) the way the Writing Tools
/// intents do: one turn through the Gemma chat template with no tools, the
/// system prompt folded in, a bounded number of tokens. Never a cloud model.
struct LocalModelWritingEngine: WritingEngine {
    let model: any LocalLanguageModel
    var timeout: Duration = .seconds(60)

    var name: String { model.modelName }

    func write(_ spec: WritingPromptSpec) async throws -> String {
        await model.resetSession()
        let prompt = GemmaChatTemplate.format(messages: [.user(spec.user)], tools: [],
                                              systemPromptOverride: spec.system)
        var config = spec.precise ? GenerationConfig.deterministic : GenerationConfig.default
        config.maxNewTokens = spec.maxTokens
        let model = self.model
        let output: String? = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                var text = ""
                for await token in try await model.generate(prompt: prompt, config: config) {
                    if Task.isCancelled { break }
                    text += token
                }
                return text
            }
            group.addTask { [timeout] in
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let output else { throw WritingEngineError.failed("timed out") }
        return output
    }
}

/// The app's side of the writing hand-off: when Anu comes to the foreground it
/// runs what the action extension or the keyboard left in the App Group, on
/// the device, and leaves the result for them. The latest result is also
/// shown in the app (with Copy), so the user isn't sent back empty-handed.
@MainActor
final class WritingHandoffRunner: ObservableObject {
    static let shared = WritingHandoffRunner()

    /// The newest finished hand-off, for the in-app sheet.
    @Published var latest: WritingHandoffResult?
    @Published private(set) var isRunning = false

    private let store: WritingHandoffStore

    init(store: WritingHandoffStore = WritingHandoffStore()) {
        self.store = store
    }

    /// Runs every pending request on `engine`. Returns the results posted.
    @discardableResult
    func process(with engine: any WritingEngine) async -> [WritingHandoffResult] {
        guard !isRunning else { return [] }
        let pending = store.takePending()
        guard !pending.isEmpty else { return [] }
        isRunning = true
        defer { isRunning = false }
        var posted: [WritingHandoffResult] = []
        for request in pending {
            let result: WritingHandoffResult
            do {
                let raw = try await engine.write(request.spec)
                if let problem = WritingOutput.problem(raw) {
                    result = WritingHandoffResult(request: request, text: nil,
                                                  failure: Self.failureText(problem), engine: engine.name)
                } else {
                    result = WritingHandoffResult(request: request, text: WritingOutput.clean(raw),
                                                  failure: nil, engine: engine.name)
                }
            } catch {
                result = WritingHandoffResult(request: request, text: nil,
                                              failure: "Anu couldn't do that on this device. Try again.",
                                              engine: engine.name)
            }
            store.post(result)
            posted.append(result)
        }
        latest = posted.last
        return posted
    }

    /// The app hook: waits for the orchestrator's model, then runs the queue on
    /// it. Skipped while a chat reply is streaming (one model, one job).
    func processIfNeeded(orchestrator: AgentOrchestrator) async {
        guard store.hasPending, !orchestrator.isThinking else { return }
        await orchestrator.setup()
        guard !orchestrator.isThinking else { return }
        orchestrator.isThinking = true
        defer { orchestrator.isThinking = false }
        await process(with: LocalModelWritingEngine(model: orchestrator.model))
    }

    /// The user has seen the result in the app; the extension can still use it.
    func dismissLatest() { latest = nil }

    private static func failureText(_ problem: String) -> String {
        problem == "empty result"
            ? "Anu didn't come up with anything. Try again."
            : "Anu couldn't do that on this device. Try again."
    }
}

/// The in-app sheet for a finished hand-off: the result, Copy, and where to
/// go to put it back.
struct WritingHandoffResultView: View {
    let result: WritingHandoffResult
    var onDone: () -> Void
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let text = result.text {
                        Text(text).textSelection(.enabled)
                    } else {
                        Text(result.failure ?? "Anu couldn't do that.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("\(result.label) · On this device · \(result.engine)")
                } footer: {
                    Text(result.source == .keyboard
                         ? "Go back to the app you were typing in: Anu Keyboard shows this as a preview to Insert or Replace."
                         : "Open \"Rewrite with Anu\" on the same text again to Replace it, or copy it here.")
                }
                if let text = result.text {
                    Button(copied ? "Copied" : "Copy") {
                        Clipboard.copy(text)
                        copied = true
                    }
                }
            }
            .navigationTitle("Anu wrote this")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
            }
        }
    }
}
