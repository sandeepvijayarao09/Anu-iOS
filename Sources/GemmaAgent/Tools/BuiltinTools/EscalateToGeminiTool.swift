import Foundation

/// Tool that escalates a sub-task to the Gemini API for more capable processing
struct EscalateToGeminiTool: Tool {
    let name = "escalate_to_gemini"
    let description = "Escalates a complex task to Google Gemini for advanced reasoning, detailed code generation, long-form writing, or tasks requiring more capability than the local model. Returns Gemini's response."

    private let geminiClient: GeminiClient

    init(geminiClient: GeminiClient) {
        self.geminiClient = geminiClient
    }

    var parameters: JSONSchema? {
        .object(
            description: "Escalation parameters",
            properties: [
                "task": .string(description: "The specific task or question to send to Gemini"),
                "context": .string(description: "Relevant context from the conversation to help Gemini understand the task")
            ],
            required: ["task"]
        )
    }

    func execute(arguments: JSONValue) async throws -> String {
        guard let rawTask = arguments["task"]?.stringValue else {
            throw ToolError.missingArgument("task")
        }
        // Defense in depth: whatever path built these arguments (model
        // classifier or the agent loop), PII is scrubbed before upload.
        // This is the single funnel for every Gemini upload, so the redaction
        // count computed here is authoritative for the privacy ledger.
        let taskResult = PIISanitizer.sanitize(rawTask)
        let contextResult = PIISanitizer.sanitize(arguments["context"]?.stringValue ?? "")
        let task = taskResult.text
        let context = contextResult.text

        let fullPrompt: String
        if context.isEmpty {
            fullPrompt = task
        } else {
            fullPrompt = """
            Context: \(context)

            Task: \(task)
            """
        }

        // Check if API key is configured
        guard !geminiClient.apiKey.isEmpty else {
            return """
            [Gemini escalation unavailable — no API key configured]

            Please add your Gemini API key in Settings to enable escalation.

            The task was: \(task)
            """
        }

        // Log the egress just before it happens — the ledger records the
        // sanitized payload (what actually leaves) and the redaction count.
        await PrivacyLedger.shared.record(
            destination: .cloud(model: GeminiClient.modelName),
            payload: fullPrompt,
            redactions: taskResult.redactions + contextResult.redactions
        )

        do {
            let response = try await geminiClient.generate(prompt: fullPrompt)
            return "[Gemini Response]\n\n\(response)"
        } catch GeminiError.unauthorized {
            return "Gemini API error: Invalid API key. Please check your key in Settings."
        } catch GeminiError.rateLimited {
            return "Gemini API error: Rate limit exceeded. Please wait and try again."
        } catch {
            return "Gemini API error: \(error.localizedDescription)"
        }
    }
}
