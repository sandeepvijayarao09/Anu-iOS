import Foundation

/// Escalates a sub-task to the private compute server. Mirrors
/// `EscalateToGeminiTool`: same PII funnel and ledger recording, different
/// destination. This tool is the authoritative redaction-count source, so the
/// client is told NOT to double-record (`recordsLedger: false`).
struct EscalateToPrivateCloudTool: Tool {
    let name = "escalate_to_private_cloud"
    let description = "Escalates a complex task to your private compute server for advanced reasoning, detailed code generation, or long-form writing beyond the local model. Personal details are redacted before sending. Returns the server's response."

    private let client: PrivateComputeClient
    private let sessionIdProvider: @Sendable () -> String

    init(client: PrivateComputeClient, sessionIdProvider: @escaping @Sendable () -> String) {
        self.client = client
        self.sessionIdProvider = sessionIdProvider
    }

    var parameters: JSONSchema? {
        .object(
            description: "Escalation parameters",
            properties: [
                "task": .string(description: "The specific task or question to send to the private server"),
                "context": .string(description: "Relevant context from the conversation to help the server understand the task")
            ],
            required: ["task"]
        )
    }

    func execute(arguments: JSONValue) async throws -> String {
        guard let rawTask = arguments["task"]?.stringValue else {
            throw ToolError.missingArgument("task")
        }
        // Single funnel: PII is scrubbed before upload regardless of which path
        // built these arguments. The redaction count here is authoritative.
        let taskResult = PIISanitizer.sanitize(rawTask)
        let contextResult = PIISanitizer.sanitize(arguments["context"]?.stringValue ?? "")
        let task = taskResult.text
        let context = contextResult.text
        let fullPrompt = context.isEmpty ? task : """
            Context: \(context)

            Task: \(task)
            """

        guard client.isConfigured else {
            return """
            [Private compute unavailable — no server configured]

            Add your private compute endpoint in Settings → Private Compute.

            The task was: \(task)
            """
        }

        // Record the egress just before it happens (sanitized payload + count).
        await PrivacyLedger.shared.record(
            destination: .privateComputeServer(endpoint: client.endpointHost),
            payload: fullPrompt,
            redactions: taskResult.redactions + contextResult.redactions
        )

        do {
            let response = try await client.generate(
                prompt: fullPrompt,
                sessionId: sessionIdProvider(),
                config: .deterministic,
                recordsLedger: false   // we already recorded above (authoritative count)
            )
            return "[Private Compute Response]\n\n\(response)"
        } catch PrivateComputeError.unauthorized {
            return "Private compute error: this device was rejected (401). Check attestation or the dev token in Settings."
        } catch PrivateComputeError.rateLimited {
            return "Private compute error: rate limit exceeded. Please wait and try again."
        } catch PrivateComputeError.attestationFailed(let why) {
            return "Private compute error: \(why)"
        } catch {
            return "Private compute error: \(error.localizedDescription)"
        }
    }
}
