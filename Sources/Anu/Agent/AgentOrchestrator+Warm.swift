import Foundation

// Warm start and named waits (Android ADR-074).
extension AgentOrchestrator {
    /// How long a wait lasts before it's named.
    static let waitNoteDelay: Duration = .seconds(1)

    /// Gets the model ready when Anu is about to be asked something (the
    /// model loaded, a new or cleared chat, voice mode, typing): it loads, and
    /// Gemma reads the chat's opening, so the first word waits for neither.
    /// Skipped under the heat or battery guard and in Low Power Mode: neither
    /// can be stopped once started, and the user may never ask. A turn waits
    /// for it (`preparing`), so the model never has two at once.
    func warmUp() {
        guard !isThinking, DeviceGuard.evaluate(deviceConditions.current()) == nil,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        let model = self.model
        let previous = preparing
        preparing = Task(priority: .utility) {
            await previous?.value
            await model.warmUp()
        }
    }

    /// While a turn is thinking, names what the model is busy with once the
    /// wait passes a second, and clears it when the model is idle.
    func startWaitWatch() {
        waitWatch?.cancel()
        let model = self.model
        waitWatch = Task { [weak self] in
            var busySince: ContinuousClock.Instant?
            while !Task.isCancelled {
                let activity = await model.activity()
                guard let self, !Task.isCancelled else { return }
                if activity == .idle {
                    busySince = nil
                    if self.waitNote != nil { self.waitNote = nil }
                } else {
                    let since = busySince ?? .now
                    busySince = since
                    if ContinuousClock.now - since >= Self.waitNoteDelay {
                        let note = activity.waitNote(modelName: model.modelName)
                        if self.waitNote != note { self.waitNote = note }
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stopWaitWatch() {
        waitWatch?.cancel()
        waitWatch = nil
        waitNote = nil
    }
}
