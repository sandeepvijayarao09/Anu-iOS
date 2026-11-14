#if canImport(FoundationModels) && compiler(>=6.4)  // iOS 27 SDK APIs (Xcode 27)
import XCTest
import os
import FoundationModels
@testable import Anu

/// The Foundation Models side of parity A1–A3, with no Apple Intelligence
/// needed: Anu's tools as `Tool`s (schemas, arguments, the broker hand-off),
/// error and option mapping, and Gemma behind Apple's `LanguageModel`
/// protocol driven by a real `LanguageModelSession` over a scripted backend.
@MainActor
final class FoundationModelsBridgeTests: XCTestCase {
    private func requireIOS27() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { throw XCTSkip("Needs the iOS 27 runtime") }
    }

    // MARK: Tool bridge

    func testEveryRegisteredToolHasAValidGenerationSchema() throws {
        try requireIOS27()
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fm-\(UUID().uuidString)")
        let orch = AgentOrchestrator(model: QueuedMockModel([]), sessionsDirectory: dir)
        let tools = orch.toolRegistry.allTools + [EscalateToApplePCCTool(generator: nil)]
        XCTAssertFalse(tools.isEmpty)
        for tool in tools {
            XCTAssertNoThrow(try FoundationModelsToolBridge.generationSchema(for: tool), tool.name)
        }
        let bridged = FoundationModelsToolBridge.tools(for: tools) { _ in "" }
        XCTAssertEqual(bridged.map(\.name), tools.map(\.name))
    }

    func testSchemaKeepsPropertiesAndRequiredness() throws {
        try requireIOS27()
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let schema = try FoundationModelsToolBridge.generationSchema(for: RemindersTool())
        let json = String(data: try JSONEncoder().encode(schema), encoding: .utf8) ?? ""
        for key in ["action", "title", "due", "repeat", "create", "cancel"] {
            XCTAssertTrue(json.contains(key), "\(key) missing from \(json)")
        }
        XCTAssertTrue(json.contains("required"), json)
    }

    func testArgumentsComeBackAsAnuJSON() throws {
        try requireIOS27()
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let content = try GeneratedContent(json: #"{"action": "create", "title": "Milk", "count": 2}"#)
        XCTAssertEqual(FoundationModelsToolBridge.jsonValue(content),
                       .object(["action": .string("create"), "title": .string("Milk"), "count": .int(2)]))
    }

    func testABrokeredToolOnlyHandsTheCallBack() async throws {
        try requireIOS27()
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let seen = OSAllocatedUnfairLock<[ToolCallInfo]>(initialState: [])
        let tool = BrokeredTool(name: "calculator", description: "math",
                                parameters: try FoundationModelsToolBridge.generationSchema(for: CalculatorTool())) { info in
            seen.withLock { $0.append(info) }
            return "observation from the broker"
        }
        let output = try await tool.call(arguments: try GeneratedContent(json: #"{"expression": "2+2"}"#))
        XCTAssertEqual(output, "observation from the broker")
        XCTAssertEqual(seen.withLock { $0.first?.name }, "calculator")
        XCTAssertEqual(seen.withLock { $0.first?.arguments }, .object(["expression": .string("2+2")]))
    }

    // MARK: Apple model plumbing

    func testSnapshotDeltas() throws {
        try requireIOS27()
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        XCTAssertEqual(AppleFoundationModel.delta(from: "", to: "Hel"), "Hel")
        XCTAssertEqual(AppleFoundationModel.delta(from: "Hel", to: "Hello"), "lo")
        XCTAssertEqual(AppleFoundationModel.delta(from: "Thinking", to: "It's 4"), "It's 4", "a restart after a tool call")
    }

    func testErrorsMapToHonestReasons() throws {
        try requireIOS27()
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let reset = Date().addingTimeInterval(3600)
        let quota = PrivateCloudComputeLanguageModel.Error.quotaLimitReached(.init(resetDate: reset, debugDescription: "q"))
        XCTAssertEqual(FoundationModelsErrors.map(quota), .unavailable(.quotaExhausted(resetDate: reset)))
        let network = PrivateCloudComputeLanguageModel.Error.networkFailure(.init(debugDescription: "n"))
        XCTAssertEqual(FoundationModelsErrors.map(network), .unavailable(.temporarilyUnreachable))
        let tooLong = LanguageModelError.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: "c"))
        XCTAssertEqual(FoundationModelsErrors.map(tooLong), .tooLong)
        XCTAssertTrue(AgentOrchestrator.isPromptTooLong(FoundationModelsErrors.tooLongMarker(.onDevice)))
    }

    func testOptionsFollowAnuConfig() throws {
        try requireIOS27()
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        var config = GenerationConfig.deterministic
        config.maxNewTokens = 200
        let options = FoundationModelsOptions.generation(from: config, toolsOffered: true)
        XCTAssertEqual(options.maximumResponseTokens, 200)
        XCTAssertEqual(options.toolCallingMode, .allowed)
        XCTAssertEqual(FoundationModelsOptions.generation(from: config, toolsOffered: false).toolCallingMode, .disallowed)
    }

    func testTranscriptCarriesInstructionsAndHistory() throws {
        try requireIOS27()
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let turn = NativeTurn(instructions: "Be brief.",
                              history: [.init(role: .user, text: "hi"), .init(role: .assistant, text: "hello")],
                              prompt: "bye")
        let transcript = FoundationModelsTranscript.make(turn, tools: [])
        XCTAssertEqual(transcript.count, 3)
        guard case .instructions = transcript.first, case .response = transcript.last else {
            return XCTFail("\(transcript)")
        }
    }

    func testAppleModelReportsWhyItCantLoad() async throws {
        try requireIOS27()
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let saved = AppleModels.availability
        defer { AppleModels.availability = saved }
        AppleModels.availability = FakeAppleAvailability(onDevice: .unavailable(.deviceNotEligible))
        let model = AppleFoundationModel(kind: .onDevice)
        do {
            try await model.load()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, ModelError.modelLoadFailed(AppleModelUnavailableReason.deviceNotEligible.userText).localizedDescription)
        }
        XCTAssertEqual(model.modelName, "Apple on-device")
    }

    // MARK: Gemma behind LanguageModel (A3)

    func testGemmaAnswersThroughALanguageModelSession() async throws {
        try requireIOS27()
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let backend = QueuedMockModel(["Hello from Gemma."])
        let session = LanguageModelSession(model: GemmaFoundationModel(backend: backend), instructions: "Be kind.")
        let response = try await session.respond(to: "Hi")
        XCTAssertEqual(response.content, "Hello from Gemma.")
        let prompt = try XCTUnwrap(backend.capturedPrompts.first)
        XCTAssertTrue(prompt.contains("<start_of_turn>user\nBe kind.\n\nHi<end_of_turn>"), prompt)
        XCTAssertTrue(prompt.hasSuffix("<start_of_turn>model\n"), prompt)
    }

    func testGemmaToolCallsRunTheBridgedTool() async throws {
        try requireIOS27()
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let backend = QueuedMockModel([
            #"{"tool_call": {"name": "calculator", "arguments": {"expression": "2+2"}}}"#,
            "It's 4.",
        ])
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let tool = BrokeredTool(name: "calculator", description: "Evaluates math",
                                parameters: try FoundationModelsToolBridge.generationSchema(for: CalculatorTool())) { info in
            calls.withLock { $0 += 1 }
            return info.arguments["expression"]?.stringValue == "2+2" ? "4" : "bad arguments"
        }
        let session = LanguageModelSession(model: GemmaFoundationModel(backend: backend), tools: [tool])
        let response = try await session.respond(to: "What's 2+2?")
        XCTAssertEqual(response.content, "It's 4.")
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertEqual(backend.capturedPrompts.count, 2)
        XCTAssertTrue(backend.capturedPrompts[0].contains("**calculator**"), backend.capturedPrompts[0])
        XCTAssertTrue(backend.capturedPrompts[1].contains("Tool result:\n4"), backend.capturedPrompts[1])
    }
}
#endif
