import Foundation
import os
@testable import Anu

/// A deterministic test model that returns a FIFO queue of pre-scripted
/// responses — one per `generate(...)` call — and captures the prompts it was
/// given. Essential for testing the plan pipeline, which makes many ordered
/// model calls per turn (planner → sub-agents → synthesis → critic).
///
/// State is protected by `OSAllocatedUnfairLock` (a Sendable, `withLock`-based
/// lock) rather than a bare `NSLock` whose `lock()`/`unlock()` pair is an
/// error under the Swift 6 language mode.
final class QueuedMockModel: LocalLanguageModel, Sendable {
    nonisolated let modelName = "Queued Mock"

    private struct State {
        var responses: [String]
        var capturedPrompts: [String] = []
    }
    private let state: OSAllocatedUnfairLock<State>

    init(_ responses: [String]) {
        state = OSAllocatedUnfairLock(initialState: State(responses: responses))
    }

    var capturedPrompts: [String] {
        state.withLock { $0.capturedPrompts }
    }

    func load() async throws {}

    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String> {
        let next = state.withLock { s -> String in
            s.capturedPrompts.append(prompt)
            return s.responses.isEmpty ? "Mock fallback answer" : s.responses.removeFirst()
        }
        return AsyncStream<String> { continuation in
            continuation.yield(next)
            continuation.finish()
        }
    }
}
