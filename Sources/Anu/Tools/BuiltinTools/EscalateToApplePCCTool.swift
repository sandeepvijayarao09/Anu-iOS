import Foundation

/// Answers one prompt on Apple's Private Cloud Compute model. The real one
/// lives behind `#available` in `AppleFoundationModel.swift`; tests use fakes.
protocol PrivateCloudGenerating: Sendable {
    func generate(prompt: String) async throws -> String
}

/// Why a PCC request didn't produce an answer.
enum PrivateCloudFailure: Error, Equatable {
    /// Quota, network, entitlement or readiness: the router should skip PCC.
    case unavailable(AppleModelUnavailableReason)
    /// The model answered with an error (a refusal, a guardrail): shown as is.
    case failed(String)
}

/// Escalates a hard task to Apple's Private Cloud Compute model, the private
/// cloud tier (parity A1). Same funnel as the other escalation tools: PII is
/// scrubbed, the egress is recorded in the Privacy Ledger just before it
/// happens, and the broker decides whether it runs. When PCC can't take the
/// request it says so with `unavailablePrefix`, records why in
/// `PrivateCloudBackoff` so the router stops choosing it, and the orchestrator
/// carries the turn on to the next tier.
struct EscalateToApplePCCTool: Tool {
    static let toolName = "escalate_to_apple_pcc"
    static let responsePrefix = "[Apple Private Cloud Compute Response]\n\n"
    static let unavailablePrefix = "[Apple Private Cloud Compute unavailable]"

    var timeout: Duration { ToolBroker.escalationTimeout }
    let name = EscalateToApplePCCTool.toolName
    let description = "Sends a hard task to Apple's Private Cloud Compute model, a larger model on Apple's servers that keeps nothing, for complex reasoning, code or long writing beyond the on-device model. Returns its answer."

    private let generator: (any PrivateCloudGenerating)?
    private let availability: @Sendable () -> AppleModelStatus
    private let backoff: PrivateCloudBackoff

    init(generator: (any PrivateCloudGenerating)? = ApplePrivateCloudGenerator.makeDefault(),
         availability: @escaping @Sendable () -> AppleModelStatus = { AppleModels.status(of: .privateCloud) },
         backoff: PrivateCloudBackoff = .shared) {
        self.generator = generator
        self.availability = availability
        self.backoff = backoff
    }

    var parameters: JSONSchema? {
        .object(
            description: "Escalation parameters",
            properties: [
                "task": .string(description: "The specific task or question to send"),
                "context": .string(description: "Relevant context from the conversation to help with the task"),
            ],
            required: ["task"]
        )
    }

    static func isUnavailableResult(_ result: String) -> Bool {
        result.hasPrefix(unavailablePrefix)
    }

    static func unavailable(_ reason: AppleModelUnavailableReason) -> String {
        "\(unavailablePrefix) \(reason.userText)"
    }

    func execute(arguments: JSONValue) async throws -> String {
        guard let rawTask = arguments["task"]?.stringValue else {
            throw ToolError.missingArgument("task")
        }
        let status = availability()
        if let reason = status.reason { return Self.unavailable(reason) }
        guard let generator else { return Self.unavailable(.osTooOld) }

        let taskResult = PIISanitizer.sanitize(rawTask)
        let contextResult = PIISanitizer.sanitize(arguments["context"]?.stringValue ?? "")
        let prompt = contextResult.text.isEmpty ? taskResult.text : """
            Context: \(contextResult.text)

            Task: \(taskResult.text)
            """

        await PrivacyLedger.shared.record(
            destination: .applePrivateCloud,
            payload: prompt,
            redactions: taskResult.redactions + contextResult.redactions
        )

        do {
            let answer = try await generator.generate(prompt: prompt)
            return Self.responsePrefix + answer
        } catch PrivateCloudFailure.unavailable(let reason) {
            switch reason {
            case .quotaExhausted(let reset): backoff.quotaReached(resetDate: reset)
            default: backoff.unreachable()
            }
            return Self.unavailable(reason)
        } catch PrivateCloudFailure.failed(let message) {
            return "Apple Private Cloud Compute error: \(message)"
        } catch {
            backoff.unreachable()
            return Self.unavailable(.temporarilyUnreachable)
        }
    }
}

// MARK: - Broker policy

extension EscalateToApplePCCTool {
    func describe(_ arguments: JSONValue) -> String {
        "Ask Apple's Private Cloud Compute model: " + ToolDescribing.quoted(ToolDescribing.text(arguments, "task") ?? "…")
    }
    func sendsTo(_ arguments: JSONValue) -> String? { "Apple Private Cloud Compute" }
}

/// Makes the system PCC generator where the OS has it.
enum ApplePrivateCloudGenerator {
    static func makeDefault() -> (any PrivateCloudGenerating)? {
        #if canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            return FoundationModelsPrivateCloudGenerator()
        }
        #endif
        return nil
    }
}
