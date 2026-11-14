import SwiftUI

/// The active model's speed on the Model page (ADR-073): its real use, from
/// the user's own answers on it (the middle of the last 20), and Test speed,
/// which runs a fixed made-up passage and a short summary and reports what it
/// read and wrote a second.
struct ModelSpeedSection: View {
    @ObservedObject private var orchestrator = AgentOrchestrator.shared
    @ObservedObject private var log = ModelSpeedLog.shared
    @State private var testing: Task<Void, Never>?
    @State private var testError: String?

    private var modelName: String { orchestrator.model.modelName }

    var body: some View {
        Section {
            if let summary = log.summary(for: modelName) {
                LabeledContent("Real use") {
                    Text(Self.realUse(summary)).font(.anuCode).multilineTextAlignment(.trailing)
                }
                .accessibilityIdentifier("modelRealUse")
            } else {
                LabeledContent("Real use", value: "No answers yet")
                    .accessibilityIdentifier("modelRealUse")
            }
            if let test = log.tests[modelName] {
                LabeledContent("Test speed") {
                    Text(SpeedTest.summary(test)).font(.anuCode).multilineTextAlignment(.trailing)
                }
                .accessibilityIdentifier("modelTestResult")
            }
            if let testError {
                Text(testError).font(.anuLabel).foregroundStyle(.orange)
            }
            if testing != nil {
                Button(role: .destructive) {
                    testing?.cancel()
                } label: {
                    HStack(spacing: Space.tight) {
                        ProgressView().controlSize(.small)
                        Text("Testing… Stop test")
                    }
                }
                .accessibilityIdentifier("stopSpeedTest")
            } else {
                Button("Test speed") { startTest() }
                    .disabled(orchestrator.modelLoadState != .ready || orchestrator.isThinking)
                    .accessibilityIdentifier("testSpeedButton")
            }
        } header: {
            Text("Speed")
        } footer: {
            Text("Real use is the middle of your last \(ModelSpeedLog.kept) answers on this model. Test speed reads a fixed made-up passage and writes a short summary, under the same lock as chat. “About” marks estimates, when the model doesn't report its own token counts.")
        }
    }

    private func startTest() {
        testError = nil
        testing = Task {
            do {
                _ = try await orchestrator.testSpeed()
            } catch {
                testError = error.localizedDescription
            }
            testing = nil
        }
    }

    static func realUse(_ s: SpeedSummary) -> String {
        var parts: [String] = []
        if let r = s.writeRate { parts.append("writes \(AnswerDetailsText.perSecond(r, counted: s.counted))") }
        if let r = s.readRate { parts.append("reads \(AnswerDetailsText.perSecond(r, counted: s.counted))") }
        if let ms = s.firstWordMs { parts.append("first word \(AnswerDetailsText.seconds(ms))") }
        let answers = s.answers == 1 ? "1 answer" : "\(s.answers) answers"
        return (parts + [answers]).joined(separator: " · ")
    }
}
