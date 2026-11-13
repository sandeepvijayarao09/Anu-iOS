#if canImport(FoundationModels)
import Foundation
import os
import FoundationModels

// MARK: - Apple's models behind Anu's LocalLanguageModel (parity A1, A2)
//
// `AppleFoundationModel` puts Apple's on-device model (or the Private Cloud
// Compute model) behind the same protocol as Gemma, so the router, About this
// answer, Test speed and the model picker work unchanged:
//  • `generate(prompt:)` takes Anu's Gemma-templated prompt (chat, headless,
//    planner, judge, speed test), parses it back into turns and runs them as a
//    Foundation Models transcript;
//  • `respondNatively` runs an agent turn with native tool calling; every tool
//    is a `BrokeredTool` whose `call` hands the request back to Anu's broker.
// Errors that happen before the first word throw with an honest reason; a
// context overflow comes back as LiteRT-LM's "too long" marker so the
// orchestrator's existing retry-with-fewer-tools and wording apply.

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
final class AppleFoundationModel: NativeToolCallingModel, @unchecked Sendable {
    let kind: AppleModelKind
    private let usage = OSAllocatedUnfairLock<GenerationUsage?>(initialState: nil)

    init(kind: AppleModelKind = .onDevice) {
        self.kind = kind
    }

    var modelName: String { kind.displayName }

    /// Apple's on-device context is 4K tokens (Apple's doc table); PCC's 32K.
    var nativeToolBudgetTokens: Int { kind == .onDevice ? 900 : 4_000 }

    func load() async throws {
        if let reason = AppleModels.status(of: kind).reason {
            throw ModelError.modelLoadFailed(reason.userText)
        }
        if kind == .onDevice {
            LanguageModelSession(model: SystemLanguageModel.default).prewarm()
        }
    }

    func lastUsage() async -> GenerationUsage? { usage.withLock { $0 } }

    func countTokens(_ text: String) async -> Int? {
        guard kind == .onDevice else { return nil }
        return try? await SystemLanguageModel.default.tokenCount(for: text)
    }

    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncStream<String> {
        try await run(NativeTurn.fromGemmaPrompt(prompt), tools: [], config: config)
    }

    func respondNatively(_ turn: NativeTurn, tools: [any Tool], config: GenerationConfig,
                         onToolCall: @escaping @Sendable (ToolCallInfo) async -> String) async throws -> AsyncStream<String> {
        try await run(turn, tools: FoundationModelsToolBridge.tools(for: tools, handler: onToolCall), config: config)
    }

    // MARK: Session

    private func makeSession(tools: [any FoundationModels.Tool], transcript: Transcript) -> LanguageModelSession {
        switch kind {
        case .onDevice:
            return LanguageModelSession(model: SystemLanguageModel.default, tools: tools, transcript: transcript)
        case .privateCloud:
            return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, transcript: transcript)
        }
    }

    private func run(_ turn: NativeTurn, tools: [any FoundationModels.Tool], config: GenerationConfig) async throws -> AsyncStream<String> {
        usage.withLock { $0 = nil }
        if let reason = AppleModels.status(of: kind).reason {
            throw ModelError.generationFailed(reason.userText)
        }
        let session = makeSession(tools: tools, transcript: FoundationModelsTranscript.make(turn, tools: tools))
        let options = FoundationModelsOptions.generation(from: config, toolsOffered: !tools.isEmpty)
        let context = kind == .privateCloud ? ContextOptions(reasoningLevel: .moderate) : ContextOptions()
        let kind = self.kind
        let usage = self.usage
        let started = Date()

        let (events, sink) = AsyncStream<StreamEvent>.makeStream()
        let pump = Task {
            var shown = ""
            var first: Date?
            do {
                for try await snapshot in session.streamResponse(to: turn.prompt, options: options, contextOptions: context) {
                    if Task.isCancelled { break }
                    let content = snapshot.content
                    let delta = Self.delta(from: shown, to: content)
                    shown = content
                    if !delta.isEmpty {
                        if first == nil { first = Date() }
                        sink.yield(.text(delta))
                    }
                    let measured = snapshot.usage
                    let firstOutput = first
                    usage.withLock {
                        $0 = GenerationUsage(
                            promptTokens: measured.input.totalTokenCount,
                            outputTokens: measured.output.totalTokenCount,
                            counted: true,
                            backend: kind == .onDevice ? "Apple Intelligence" : "Apple PCC",
                            firstOutputMs: firstOutput.map { Int($0.timeIntervalSince(started) * 1000) },
                            decodeMs: firstOutput.map { Int(Date().timeIntervalSince($0) * 1000) })
                    }
                }
            } catch {
                sink.yield(.failure(FoundationModelsErrors.map(error)))
            }
            sink.finish()
        }

        var iterator = events.makeAsyncIterator()
        let head = await iterator.next()
        let rest = iterator
        switch head {
        case .failure(let mapped)?:
            pump.cancel()
            if mapped == .tooLong { return Self.single(FoundationModelsErrors.tooLongMarker(kind)) }
            throw ModelError.generationFailed(mapped.userText)
        case nil:
            return Self.single("")
        case .text(let firstText)?:
            return AsyncStream<String> { continuation in
                continuation.yield(firstText)
                let forward = Task {
                    var tail = rest
                    while let event = await tail.next() {
                        switch event {
                        case .text(let text): continuation.yield(text)
                        case .failure(let mapped):
                            continuation.yield(mapped == .tooLong
                                ? FoundationModelsErrors.tooLongMarker(kind)
                                : "\n\n(\(mapped.userText))")
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in
                    forward.cancel()
                    pump.cancel()
                }
            }
        }
    }

    private enum StreamEvent: Sendable {
        case text(String)
        case failure(FoundationModelsErrors.Mapped)
    }

    private static func single(_ text: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            if !text.isEmpty { continuation.yield(text) }
            continuation.finish()
        }
    }

    /// What's new in a cumulative snapshot. After a tool call the response can
    /// start over, which shows as a snapshot that doesn't extend the last.
    static func delta(from shown: String, to content: String) -> String {
        if content.hasPrefix(shown) { return String(content.dropFirst(shown.count)) }
        return content
    }
}

// MARK: - Transcript and options

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
enum FoundationModelsTranscript {
    /// Instructions (with the offered tools' definitions), then the earlier
    /// conversation. The newest user message is sent as the prompt.
    static func make(_ turn: NativeTurn, tools: [any FoundationModels.Tool]) -> Transcript {
        var entries: [Transcript.Entry] = []
        if !turn.instructions.isEmpty || !tools.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: turn.instructions.isEmpty ? [] : [.text(Transcript.TextSegment(content: turn.instructions))],
                toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) })))
        }
        for entry in turn.history {
            let segments: [Transcript.Segment] = [.text(Transcript.TextSegment(content: entry.text))]
            switch entry.role {
            case .user: entries.append(.prompt(Transcript.Prompt(segments: segments)))
            case .assistant: entries.append(.response(Transcript.Response(assetIDs: [], segments: segments)))
            }
        }
        return Transcript(entries: entries)
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
enum FoundationModelsOptions {
    static func generation(from config: GenerationConfig, toolsOffered: Bool) -> GenerationOptions {
        GenerationOptions(
            samplingMode: config.temperature <= 0 ? .greedy : nil,
            temperature: config.temperature <= 0 ? nil : Double(config.temperature),
            maximumResponseTokens: config.maxNewTokens > 0 ? config.maxNewTokens : nil,
            toolCallingMode: toolsOffered ? .allowed : .disallowed)
    }
}

// MARK: - Errors

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
enum FoundationModelsErrors {
    enum Mapped: Equatable, Sendable {
        case tooLong
        case unavailable(AppleModelUnavailableReason)
        case message(String)

        var userText: String {
            switch self {
            case .tooLong: return "That was too long for Apple's model to take in at once."
            case .unavailable(let reason): return reason.userText
            case .message(let text): return text
            }
        }
    }

    /// The marker the orchestrator already treats as "prompt too long".
    static func tooLongMarker(_ kind: AppleModelKind) -> String {
        "[Generation error: Exceeding the maximum number of tokens (\(kind.displayName))]"
    }

    static func map(_ error: any Error) -> Mapped {
        if let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded: return .tooLong
            case .guardrailViolation, .refusal:
                return .message("Apple's model won't answer that. Try rephrasing it, or pick Gemma 4 in Settings → Model.")
            case .rateLimited(let limit): return .unavailable(.quotaExhausted(resetDate: limit.resetDate))
            case .unsupportedLanguageOrLocale:
                return .message("Apple's model doesn't support this language yet. Pick Gemma 4 in Settings → Model.")
            case .timeout: return .message("Apple's model took too long to answer. Please try again.")
            default: return .message(error.localizedDescription)
            }
        }
        if let error = error as? PrivateCloudComputeLanguageModel.Error {
            switch error {
            case .quotaLimitReached(let quota): return .unavailable(.quotaExhausted(resetDate: quota.resetDate))
            case .networkFailure, .serviceUnavailable: return .unavailable(.temporarilyUnreachable)
            @unknown default: return .unavailable(.temporarilyUnreachable)
            }
        }
        if error is SystemLanguageModel.Error { return .unavailable(.modelNotReady) }
        return .message(error.localizedDescription)
    }
}

// MARK: - Private Cloud Compute escalation

/// One prompt to Apple's PCC model, for `EscalateToApplePCCTool`.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
struct FoundationModelsPrivateCloudGenerator: PrivateCloudGenerating {
    func generate(prompt: String) async throws -> String {
        let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel())
        do {
            let response = try await session.respond(to: prompt, contextOptions: ContextOptions(reasoningLevel: .moderate))
            return response.content
        } catch {
            switch FoundationModelsErrors.map(error) {
            case .unavailable(let reason): throw PrivateCloudFailure.unavailable(reason)
            case .tooLong: throw PrivateCloudFailure.failed("The task was too long for Private Cloud Compute.")
            case .message(let text): throw PrivateCloudFailure.failed(text)
            }
        }
    }
}

// MARK: - Anu tools as Foundation Models tools (parity A2)

/// One of Anu's tools, offered to a Foundation Models session. The model
/// proposes; `call` hands the request back to Anu (`handler` → ToolBroker)
/// and returns the broker's observation. It never runs the tool itself.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
struct BrokeredTool: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let handler: @Sendable (ToolCallInfo) async -> String

    func call(arguments: GeneratedContent) async throws -> String {
        await handler(ToolCallInfo(name: name, arguments: FoundationModelsToolBridge.jsonValue(arguments)))
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
enum FoundationModelsToolBridge {
    /// Anu's tools as Foundation Models tools. A tool whose schema can't be
    /// expressed is left out rather than offered wrongly.
    static func tools(for tools: [any Tool], handler: @escaping @Sendable (ToolCallInfo) async -> String) -> [any FoundationModels.Tool] {
        tools.compactMap { tool in
            guard let schema = try? generationSchema(for: tool) else { return nil }
            return BrokeredTool(name: tool.name, description: tool.description, parameters: schema, handler: handler)
        }
    }

    /// An Anu `JSONSchema` as a Foundation Models generation schema.
    static func generationSchema(for tool: any Tool) throws -> GenerationSchema {
        let root = dynamicSchema(tool.parameters ?? .object(properties: [:]), name: "\(tool.name)_arguments")
        return try GenerationSchema(root: root, dependencies: [])
    }

    static func dynamicSchema(_ schema: JSONSchema, name: String) -> DynamicGenerationSchema {
        if schema.acceptsAnyValue { return DynamicGenerationSchema(type: String.self) }
        switch schema.type {
        case .object:
            let required = Set(schema.required ?? [])
            let properties = (schema.properties ?? [:]).sorted { $0.key < $1.key }.map { key, value in
                DynamicGenerationSchema.Property(
                    name: key, description: value.description,
                    schema: dynamicSchema(value, name: "\(name)_\(key)"),
                    isOptional: !required.contains(key))
            }
            return DynamicGenerationSchema(name: name, description: schema.description, properties: properties)
        case .string:
            let choices = (schema.enumValues ?? []).compactMap(\.stringValue)
            if !choices.isEmpty { return DynamicGenerationSchema(name: name, description: schema.description, anyOf: choices) }
            return DynamicGenerationSchema(type: String.self)
        case .integer: return DynamicGenerationSchema(type: Int.self)
        case .number: return DynamicGenerationSchema(type: Double.self)
        case .boolean: return DynamicGenerationSchema(type: Bool.self)
        case .array:
            return DynamicGenerationSchema(arrayOf: dynamicSchema(schema.items ?? .string(), name: "\(name)_item"))
        case .null: return DynamicGenerationSchema(type: String.self)
        }
    }

    /// The model's arguments as Anu's JSON value, for the broker to validate.
    static func jsonValue(_ content: GeneratedContent) -> JSONValue {
        guard let data = content.jsonString.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .object([:]) }
        return value
    }
}
#endif
