#if canImport(FoundationModels) && compiler(>=6.4)  // iOS 27 SDK APIs (Xcode 27)
import CoreGraphics
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

    /// Warm start (ADR-074): Apple's own prewarm, which loads the model
    /// without answering anything.
    func warmUp() async { try? await load() }

    /// Whether this model can reason before answering (the thinking switch).
    var supportsThinking: Bool { capabilities?.contains(.reasoning) ?? false }

    /// Whether this model can look at pictures.
    var canSee: Bool { capabilities?.contains(.vision) ?? false }

    private var capabilities: LanguageModelCapabilities? {
        switch kind {
        case .onDevice: return SystemLanguageModel.default.capabilities
        case .privateCloud: return PrivateCloudComputeLanguageModel().capabilities
        }
    }

    /// The reasoning level for a turn: Private Cloud Compute reasons a little
    /// by default; the thinking switch asks either model to reason more.
    func reasoningLevel(thinking: Bool) -> ContextOptions.ReasoningLevel? {
        switch kind {
        case .onDevice: return thinking && supportsThinking ? .light : nil
        case .privateCloud: return thinking ? .deep : .moderate
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

    /// Photos go to the model as image attachments when it can see them.
    /// When it can't, it says so rather than answering without the picture.
    func generate(prompt: String, images: [CGImage], config: GenerationConfig) async throws -> AsyncStream<String> {
        guard !images.isEmpty else { return try await generate(prompt: prompt, config: config) }
        guard canSee else {
            throw ModelError.generationFailed(
                "\(modelName) can't look at pictures on this device. Pick Gemma 4 in Settings → Model to ask about photos.")
        }
        return try await run(NativeTurn.fromGemmaPrompt(prompt), tools: [], config: config,
                             images: Array(images.prefix(PictureBudget.maxInView)))
    }

    func generate(prompt: String, image: CGImage?, config: GenerationConfig) async throws -> AsyncStream<String> {
        try await generate(prompt: prompt, images: image.map { [$0] } ?? [], config: config)
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

    private func run(_ turn: NativeTurn, tools: [any FoundationModels.Tool], config: GenerationConfig,
                     images: [CGImage] = []) async throws -> AsyncStream<String> {
        usage.withLock { $0 = nil }
        if let reason = AppleModels.status(of: kind).reason {
            throw ModelError.generationFailed(reason.userText)
        }
        let session = makeSession(tools: tools, transcript: FoundationModelsTranscript.make(turn, tools: tools))
        let options = FoundationModelsOptions.generation(from: config, toolsOffered: !tools.isEmpty)
        let context = ContextOptions(reasoningLevel: reasoningLevel(thinking: config.thinking))
        // Pictures go with the newest message, after its words.
        let prompt = Prompt {
            turn.prompt
            for image in images { Attachment(image) }
        }
        let kind = self.kind
        let usage = self.usage
        let started = Date()

        let (events, sink) = AsyncStream<StreamEvent>.makeStream()
        let pump = Task {
            var shown = ""
            var first: Date?
            do {
                for try await snapshot in session.streamResponse(to: prompt, options: options, contextOptions: context) {
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
                    // The model's reasoning, kept apart from the answer and
                    // shown collapsed under it (ADR-077), never fed back.
                    let thought = FoundationModelsTranscript.reasoningText(snapshot.transcriptEntries)
                    usage.withLock {
                        $0 = GenerationUsage(
                            promptTokens: measured.input.totalTokenCount,
                            outputTokens: measured.output.totalTokenCount,
                            counted: true,
                            backend: kind == .onDevice ? "Apple Intelligence" : "Apple PCC",
                            thought: thought.isEmpty ? nil : thought,
                            thoughtMs: thought.isEmpty ? nil : firstOutput.map { Int($0.timeIntervalSince(started) * 1000) },
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
    /// The text of the reasoning entries in `entries`.
    static func reasoningText(_ entries: ArraySlice<Transcript.Entry>) -> String {
        entries.compactMap { entry -> String? in
            guard case .reasoning(let reasoning) = entry else { return nil }
            let text = reasoning.segments.compactMap { segment -> String? in
                if case .text(let part) = segment { return part.content }
                return nil
            }.joined()
            return text.isEmpty ? nil : text
        }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

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

// MARK: - Memory extraction with guided generation

#if canImport(FoundationModels) && compiler(>=6.4)  // iOS 27 SDK APIs (Xcode 27)
/// Apple's on-device model learns memory too (§8.2), with guided generation:
/// the model fills in this shape, so there is no JSON to parse or repair.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
extension AppleFoundationModel: OnDeviceLanguageModel, GuidedFactExtracting {
    var runsOnDevice: Bool { kind == .onDevice }

    @Generable(description: "The lasting facts one message states")
    struct GuidedFacts {
        @Guide(description: "Each lasting fact; none when nothing qualifies", .maximumCount(8))
        var facts: [GuidedFact]
    }

    @Generable(description: "One lasting fact")
    struct GuidedFact {
        @Guide(description: "Who the fact is about: \"user\" for the user, else a name")
        var subject: String
        @Guide(description: "The relation in snake_case, such as lives_in, works_at, manager, diet, likes")
        var predicate: String
        @Guide(description: "The value in a few words")
        var value: String
        @Guide(description: "The memory section", .anyOf(["identity", "people", "work", "routines", "preferences", "goals", "places"]))
        var section: String
        @Guide(description: "The exact words from the message that state the fact")
        var quote: String
        @Guide(description: "True for health, money, religion, politics or sexuality")
        var sensitive: Bool
        @Guide(description: "True when a person has one of these at a time, such as where they live")
        var single: Bool
        @Guide(description: "For a fact that starts later, the day it begins as YYYY-MM-DD; else empty")
        var starts: String
    }

    func extractFacts(from message: String, instructions: String) async throws -> [ExtractedFact] {
        guard runsOnDevice else { throw ModelError.generationFailed("Memory is learned on the phone only.") }
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 512)
        let answer = try await session.respond(to: FactExtractor.messageHeader + message,
                                               generating: GuidedFacts.self, options: options)
        return answer.content.facts.map(Self.fact)
    }

    static func fact(_ g: GuidedFact) -> ExtractedFact {
        let section = FactSection(rawValue: g.section).flatMap { $0 == .notes ? nil : $0 }
            ?? (MemoryNormalize.subject(g.subject) == MemoryFact.user ? .identity : .people)
        let starts = g.starts.trimmingCharacters(in: .whitespaces)
        return ExtractedFact(subject: g.subject, predicate: g.predicate, value: g.value, section: section,
                             quote: g.quote, sensitive: g.sensitive, single: g.single,
                             starts: starts.isEmpty ? nil : starts)
    }
}
#endif
