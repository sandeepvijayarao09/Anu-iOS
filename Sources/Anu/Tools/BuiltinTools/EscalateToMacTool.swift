import Foundation

/// Escalates a sub-task to the user's own Mac running Ollama (ADR-113).
/// Mirrors `EscalateToGeminiTool` and `EscalateToPrivateCloudTool`; the egress
/// gate (PII sanitizer + Privacy Ledger, Mac as destination) is in
/// `MacBrainClient`, so every path to the Mac is gated the same way. Only text
/// goes: photos and other media stay on the phone. No tools are offered to the
/// Mac, and any it proposes are reported, not run.
struct EscalateToMacTool: Tool {
    let name = "escalate_to_mac"
    let description = "Escalates a complex task to the larger model on the user's own Mac for advanced reasoning, detailed code generation, or long-form writing beyond the local model. Personal details are redacted before sending. Returns the Mac's response."

    /// Read when the tool runs, so a change in Settings → Your Mac applies at once.
    private let makeClient: @Sendable () -> MacBrainClient

    init(makeClient: @escaping @Sendable () -> MacBrainClient = { MacBrainClient() }) {
        self.makeClient = makeClient
    }

    var parameters: JSONSchema? {
        .object(
            description: "Escalation parameters",
            properties: [
                "task": .string(description: "The specific task or question to send to the user's Mac"),
                "context": .string(description: "Relevant context from the conversation to help the Mac's model understand the task")
            ],
            required: ["task"]
        )
    }

    func execute(arguments: JSONValue) async throws -> String {
        guard let task = arguments["task"]?.stringValue else {
            throw ToolError.missingArgument("task")
        }
        let context = arguments["context"]?.stringValue ?? ""
        // Raw text in: the client is the single funnel that sanitizes and
        // ledgers, so its redaction count is the authoritative one.
        let prompt = context.isEmpty ? task : """
            Context: \(context)

            Task: \(task)
            """

        let client = makeClient()
        guard client.isConfigured else {
            return """
            [Your Mac unavailable — no Mac set up]

            Add your Mac's address in Settings → Your Mac.

            The task was: \(PIISanitizer.sanitize(task).text)
            """
        }
        do {
            let answer = try await client.generate(prompt: prompt)
            return CloudProvider.mac.responsePrefix + answer
        } catch let error as MacBrainError {
            return "Mac error: \(error.errorDescription ?? "unknown")"
        } catch let error as VaultError {
            return "Mac error: \(error.errorDescription ?? "the vault refused the token")"
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .timedOut
            || error.code == .cannotFindHost || error.code == .notConnectedToInternet {
            return "Mac error: your Mac didn't answer. Is it awake, on the same Wi-Fi, and running Ollama?"
        } catch {
            return "Mac error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Broker policy

extension EscalateToMacTool {
    func describe(_ arguments: JSONValue) -> String {
        let host = MacBrainConfig.load().map { " (\($0.destination))" } ?? ""
        return "Ask your Mac\(host): " + ToolDescribing.quoted(ToolDescribing.text(arguments, "task") ?? "…")
    }
    func sendsTo(_ arguments: JSONValue) -> String? { MacBrainConfig.load()?.destination ?? "your Mac" }
}
