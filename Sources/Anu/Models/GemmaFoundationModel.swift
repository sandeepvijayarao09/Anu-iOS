#if canImport(FoundationModels) && compiler(>=6.4)  // iOS 27 SDK APIs (Xcode 27)
import Foundation
import FoundationModels

// MARK: - Gemma behind Apple's LanguageModel protocol (parity A3)
//
// Lets one `LanguageModelSession` API drive Gemma (LiteRT-LM) as well as
// Apple's models: `LanguageModelSession(model: GemmaFoundationModel(backend:))`
// with the same `Tool`s, transcript and options.
//
// It is NOT the default path for Gemma. A `LanguageModelExecutor` is
// stateless: every call receives the whole `Transcript` and must re-render and
// re-send it, so LiteRT-LM prefills the full conversation on every turn and
// after every tool result. Anu's own path (`LiteRTLMModel`) keeps a live
// LiteRT-LM `Conversation` and sends only the newest message, reusing the KV
// cache; that matters on a phone where prefill dominates latency. Gemma 4 also
// writes tool calls in several dialects that only Anu's lenient
// `ResponseParser` reads, and the ReAct loop adds the action-claim repair the
// framework's loop doesn't have. So the orchestrator keeps driving Gemma
// directly, and this adapter is there for code that wants the uniform API.

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
struct GemmaFoundationModel: FoundationModels.LanguageModel {
    typealias Executor = GemmaFoundationExecutor

    let backend: any LocalLanguageModel
    var generationConfig: GenerationConfig = .deterministic

    init(backend: any LocalLanguageModel, generationConfig: GenerationConfig = .deterministic) {
        self.backend = backend
        self.generationConfig = generationConfig
    }

    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling]) }
    var executorConfiguration: GemmaFoundationExecutor.Configuration { .init(modelName: backend.modelName) }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
struct GemmaFoundationExecutor: LanguageModelExecutor {
    typealias Model = GemmaFoundationModel

    struct Configuration: Hashable, Sendable {
        let modelName: String
    }

    init(configuration: Configuration) throws {}

    func respond(to request: LanguageModelExecutorGenerationRequest, model: GemmaFoundationModel,
                 streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        let prompt = GemmaTranscriptRenderer.prompt(for: request.transcript, tools: request.enabledToolDefinitions)
        var config = model.generationConfig
        if let max = request.generationOptions.maximumResponseTokens { config.maxNewTokens = max }
        if let temperature = request.generationOptions.temperature { config.temperature = Float(temperature) }

        let stream = try await model.backend.generate(prompt: prompt, config: config)
        var text = ""
        var decided = false
        var holding = false
        for await piece in stream {
            try Task.checkCancellation()
            text += piece
            if !decided {
                let start = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !start.isEmpty else { continue }
                decided = true
                // A tool call is held back whole; plain text streams as it comes.
                holding = !request.enabledToolDefinitions.isEmpty && GemmaTranscriptRenderer.mayBeToolCall(start)
                if !holding { await channel.send(.response(action: .appendText(text, tokenCount: 1))) }
            } else if !holding {
                await channel.send(.response(action: .appendText(piece, tokenCount: 1)))
            }
        }

        if holding {
            let offered = Set(request.enabledToolDefinitions.map(\.name))
            switch ResponseParser.parse(text) {
            case .callTool(let call) where offered.contains(call.name):
                await channel.send(.toolCalls(action: .toolCall(
                    id: call.id, name: call.name,
                    action: .appendArguments(call.arguments.canonicalJSON, tokenCount: 1))))
            case .answerLocally(let answer):
                await channel.send(.response(action: .appendText(answer, tokenCount: 1)))
            default:
                await channel.send(.response(action: .appendText(text, tokenCount: 1)))
            }
        }

        if let usage = await model.backend.lastUsage() {
            await channel.send(.response(action: .updateUsage(
                input: .init(totalTokenCount: usage.promptTokens ?? 0, cachedTokenCount: 0),
                output: .init(totalTokenCount: usage.outputTokens ?? 0, reasoningTokenCount: 0))))
        }
    }
}

/// Renders a Foundation Models transcript in Gemma's chat template, with Anu's
/// JSON tool-call contract for the enabled tools (the same wording the ReAct
/// prompt uses, so Gemma's parser-tolerant output reads back the same way).
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
enum GemmaTranscriptRenderer {
    static func prompt(for transcript: Transcript, tools: [Transcript.ToolDefinition]) -> String {
        var system = ""
        var turns: [(role: String, text: String)] = []
        for entry in transcript {
            switch entry {
            case .instructions(let instructions):
                system += text(of: instructions.segments)
            case .prompt(let prompt):
                turns.append(("user", text(of: prompt.segments)))
            case .response(let response):
                turns.append(("model", text(of: response.segments)))
            case .toolCalls(let calls):
                for call in calls {
                    turns.append(("model", #"{"tool_call": {"name": "\#(call.toolName)", "arguments": \#(call.arguments.jsonString)}}"#))
                }
            case .toolOutput(let output):
                turns.append(("user", "Tool result:\n" + text(of: output.segments)))
            default:
                continue
            }
        }
        system += toolBlock(tools)

        var prompt = ""
        var systemPending = !system.isEmpty
        for turn in turns {
            var body = turn.text
            if systemPending, turn.role == "user" {
                body = system.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + body
                systemPending = false
            }
            prompt += "<start_of_turn>\(turn.role)\n\(body)<end_of_turn>\n"
        }
        return prompt + "<start_of_turn>model\n"
    }

    static func toolBlock(_ tools: [Transcript.ToolDefinition]) -> String {
        guard !tools.isEmpty else { return "" }
        var block = "\n\nAvailable tools:\n"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for tool in tools {
            block += "- **\(tool.name)**: \(tool.description)\n"
            if let data = try? encoder.encode(tool.parameters), let json = String(data: data, encoding: .utf8) {
                block += "  Parameters: \(json)\n"
            }
        }
        block += """

        To call a tool, output a JSON block on its own line:
        ```json
        {"tool_call": {"name": "tool_name", "arguments": {"arg1": "value1"}}}
        ```
        Wait for the tool result before continuing.
        """
        return block
    }

    static func text(of segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            switch segment {
            case .text(let text): return text.content
            case .structure(let structure): return structure.content.jsonString
            default: return nil
            }
        }.joined(separator: "\n")
    }

    /// Whether the start of a reply looks like one of Gemma's tool-call forms.
    static func mayBeToolCall(_ start: String) -> Bool {
        start.hasPrefix("{") || start.hasPrefix("```") || start.hasPrefix("<") || start.hasPrefix("[")
    }
}
#endif
