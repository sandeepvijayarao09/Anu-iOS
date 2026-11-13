import Foundation

/// One on-device answer's speed, kept for the model sheet's "real use"
/// (ADR-073). Numbers only: no content.
struct SpeedSample: Codable, Sendable, Equatable {
    var writeRate: Double?
    var readRate: Double?
    var firstWordMs: Int?
    var counted: Bool
    var at: Date
}

/// The model sheet's speed line: the middle of the last answers on a model.
struct SpeedSummary: Sendable, Equatable {
    var answers: Int
    var writeRate: Double?
    var readRate: Double?
    var firstWordMs: Int?
    var counted: Bool

    static func of(_ samples: [SpeedSample]) -> SpeedSummary? {
        guard !samples.isEmpty else { return nil }
        return SpeedSummary(
            answers: samples.count,
            writeRate: median(samples.compactMap(\.writeRate)),
            readRate: median(samples.compactMap(\.readRate)),
            firstWordMs: median(samples.compactMap(\.firstWordMs).map(Double.init)).map { Int($0.rounded()) },
            counted: samples.allSatisfy(\.counted)
        )
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}

/// The last Test speed result for a model (ADR-073).
struct SpeedTestResult: Codable, Sendable, Equatable {
    var readRate: Double?
    var writeRate: Double?
    var firstWordMs: Int?
    var tokensIn: Int
    var tokensOut: Int
    var counted: Bool
    var at: Date
}

/// Real use and the last Test speed per on-device model, kept across launches.
/// Speeds and model names aren't personal data, so they sit in UserDefaults.
@MainActor
final class ModelSpeedLog: ObservableObject {
    static let shared = ModelSpeedLog(defaults: .standard)

    /// How many recent answers "real use" summarizes.
    static let kept = 20
    static let samplesKey = "model_speed_samples"
    static let testsKey = "model_speed_tests"

    @Published private(set) var samples: [String: [SpeedSample]] = [:]
    @Published private(set) var tests: [String: SpeedTestResult] = [:]
    private let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        if let data = defaults?.data(forKey: Self.samplesKey),
           let saved = try? decoder.decode([String: [SpeedSample]].self, from: data) {
            samples = saved
        }
        if let data = defaults?.data(forKey: Self.testsKey),
           let saved = try? decoder.decode([String: SpeedTestResult].self, from: data) {
            tests = saved
        }
    }

    /// Adds an on-device answer's speed under its model.
    func record(_ details: AnswerDetails) {
        guard details.tier == .onDevice, details.writeRate != nil || details.firstWordMs != nil else { return }
        let sample = SpeedSample(writeRate: details.writeRate, readRate: details.readRate,
                                 firstWordMs: details.firstWordMs, counted: details.counted ?? false,
                                 at: details.completedAt ?? Date())
        var list = samples[details.modelName] ?? []
        list.append(sample)
        if list.count > Self.kept { list.removeFirst(list.count - Self.kept) }
        samples[details.modelName] = list
        save()
    }

    func record(test: SpeedTestResult, model: String) {
        tests[model] = test
        save()
    }

    func summary(for model: String) -> SpeedSummary? { SpeedSummary.of(samples[model] ?? []) }

    func clear() {
        samples = [:]
        tests = [:]
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(samples) { defaults?.set(data, forKey: Self.samplesKey) }
        if let data = try? encoder.encode(tests) { defaults?.set(data, forKey: Self.testsKey) }
    }
}

/// Test speed's fixed request (ADR-073): a made-up passage long enough to time
/// reading, and a short summary to time writing. Near-greedy sampling and a
/// fixed limit keep runs comparable. Nothing personal goes in.
enum SpeedTest {
    static let passage = """
    The harbor town of Westmere kept its lighthouse lit for two hundred years. The first keeper, a carpenter named \
    Elias Brandt, built the tower from local stone and carried the oil up its ninety steps every evening. His \
    daughter Mara took over when his knees failed, and she kept a logbook of every ship that passed: the fishing \
    boats at dawn, the ferries twice a day, and the cargo ships that stayed far out beyond the reef. In the winter \
    of the great storm, the lamp's glass cracked, and Mara held a lantern in the gallery all night so the ferry \
    could find the channel. The town gave her a silver medal, which she kept in a drawer with her father's tools. \
    When electricity reached Westmere, the council voted to automate the light, and the last keeper moved into a \
    cottage at the foot of the hill. Today the tower is a small museum. Visitors climb the ninety steps, read \
    pages from Mara's logbook behind glass, and look out at the same reef the ships once feared. On clear nights \
    the automated lamp still turns every twelve seconds, and the town still counts its beats like a heartbeat.
    """

    static var prompt: String {
        "<start_of_turn>user\n\(passage)\n\nSummarize this story in about eighty words.<end_of_turn>\n<start_of_turn>model\n"
    }

    static let config = GenerationConfig(
        maxNewTokens: 192,
        temperature: 0.0,
        topP: 1.0,
        topK: 1,
        repetitionPenalty: 1.0,
        stopSequences: ["<end_of_turn>", "<eos>"]
    )

    static func result(from run: SideGenerationResult, at date: Date = Date()) -> SpeedTestResult {
        SpeedTestResult(readRate: run.readRate, writeRate: run.writeRate, firstWordMs: run.firstWordMs,
                        tokensIn: run.tokensIn, tokensOut: run.tokensOut, counted: run.counted, at: date)
    }

    /// How a result reads on the sheet.
    static func summary(_ r: SpeedTestResult) -> String {
        var parts: [String] = []
        if let rate = r.readRate { parts.append("read \(r.tokensIn) at \(AnswerDetailsText.perSecond(rate, counted: r.counted))") }
        if let rate = r.writeRate { parts.append("wrote \(r.tokensOut) at \(AnswerDetailsText.perSecond(rate, counted: r.counted))") }
        if let ms = r.firstWordMs { parts.append("first word \(AnswerDetailsText.seconds(ms))") }
        return parts.isEmpty ? "No speed measured" : parts.joined(separator: " · ")
    }
}

extension AgentOrchestrator {
    /// Runs Test speed on the active on-device model and keeps the result.
    func testSpeed() async throws -> SpeedTestResult {
        let run = try await sideGeneration(prompt: SpeedTest.prompt, config: SpeedTest.config)
        let result = SpeedTest.result(from: run)
        if !run.stopped { ModelSpeedLog.shared.record(test: result, model: model.modelName) }
        return result
    }
}
