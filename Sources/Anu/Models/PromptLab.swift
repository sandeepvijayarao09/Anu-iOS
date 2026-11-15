import Foundation

/// The prompt lab's starting points (ADR-080): each writes an instruction,
/// which stays editable.
enum LabTemplate: String, CaseIterable, Identifiable, Sendable {
    case freeForm = "Free form"
    case rewrite = "Rewrite"
    case summarize = "Summarize"
    case code = "Code"

    var id: String { rawValue }

    var options: [String] {
        switch self {
        case .freeForm: return []
        case .rewrite: return ["Formal", "Friendly", "Shorter", "Clearer"]
        case .summarize: return ["Key points", "Paragraph", "One line"]
        case .code: return ["Swift", "Python", "JavaScript", "SQL"]
        }
    }

    /// The instruction this template writes for `option`.
    func instruction(_ option: String?) -> String {
        switch self {
        case .freeForm:
            return ""
        case .rewrite:
            return "Rewrite the user's text to be \((option ?? "clearer").lowercased()). Keep its meaning, names and numbers. Reply with the new text only."
        case .summarize:
            switch option {
            case "Key points": return "Summarize the user's text as a few short bullet points. Reply with the summary only."
            case "One line": return "Summarize the user's text in one sentence. Reply with the sentence only."
            default: return "Summarize the user's text in one short paragraph. Reply with the summary only."
            }
        case .code:
            return "Write \(option ?? "Swift") code for what the user asks. Reply with the code, then one short sentence about it."
        }
    }
}

/// The lab's sampling: what the user can try.
struct LabSampling: Equatable, Sendable {
    var temperature: Double = 0.7
    var topK: Int = 40
    var topP: Double = 0.95
    var maxTokens: Int = 512
    var thinking: Bool = false

    var config: GenerationConfig {
        GenerationConfig(
            maxNewTokens: maxTokens,
            temperature: Float(temperature),
            topP: Float(topP),
            topK: max(1, topK),
            repetitionPenalty: 1.0,
            stopSequences: GenerationConfig.turnEnds,
            thinking: thinking
        )
    }
}

enum PromptLab {
    /// A lab request: the prompt under an optional instruction, in Gemma's
    /// template. By construction it carries no memory, tools or history,
    /// whatever the chat holds (LAB-1). Gemma has no system role, so the
    /// instruction is folded into the user turn, as the chat does.
    static func prompt(instruction: String, prompt: String) -> String {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = instruction.isEmpty ? text : "\(instruction)\n\n\(text)"
        return "<start_of_turn>user\n\(body)<end_of_turn>\n<start_of_turn>model\n"
    }
}

/// What the prompt lab shows. Nothing here is saved: leaving the lab forgets it.
@MainActor
final class PromptLabModel: ObservableObject {
    typealias Runner = @MainActor (String, GenerationConfig, @escaping @MainActor (String) -> Void) async throws -> SideGenerationResult

    @Published var template: LabTemplate = .freeForm
    @Published var option: String?
    @Published var instruction = ""
    @Published var prompt = ""
    @Published var sampling = LabSampling()

    @Published private(set) var output = ""
    @Published private(set) var reasoning: String?
    @Published private(set) var speed: String?
    @Published private(set) var error: String?
    @Published private(set) var running = false
    @Published private(set) var stopped = false
    @Published private(set) var cut = false

    private let runner: Runner
    private var task: Task<Void, Never>?

    init(runner: @escaping Runner) {
        self.runner = runner
    }

    /// The lab on the app's on-device model.
    convenience init() {
        self.init { prompt, config, onToken in
            try await AgentOrchestrator.shared.sideGeneration(prompt: prompt, config: config, onToken: onToken)
        }
    }

    var canRun: Bool { !running && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func choose(_ template: LabTemplate) {
        self.template = template
        option = template.options.first
        instruction = template.instruction(option)
    }

    func choose(option: String) {
        self.option = option
        instruction = template.instruction(option)
    }

    /// Greedy: the same answer every run, for comparing instructions.
    func useGreedy() {
        sampling.temperature = 0
        sampling.topK = 1
        sampling.topP = 1
    }

    func run() {
        guard canRun else { return }
        output = ""
        reasoning = nil
        speed = nil
        error = nil
        stopped = false
        cut = false
        running = true
        let request = PromptLab.prompt(instruction: instruction, prompt: prompt)
        let config = sampling.config
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await runner(request, config) { [weak self] token in
                    self?.output += token
                }
                output = result.text
                reasoning = result.thought
                speed = result.speedLine.isEmpty ? nil : result.speedLine
                stopped = result.stopped
                cut = result.cut
            } catch is CancellationError {
                stopped = true
            } catch {
                self.error = error.localizedDescription
            }
            if Task.isCancelled { stopped = true }
            running = false
            task = nil
        }
    }

    /// Stops the run; what was written stays, marked.
    func stop() {
        task?.cancel()
    }

    /// Waits for the current run (tests).
    func waitForRun() async {
        await task?.value
    }
}
