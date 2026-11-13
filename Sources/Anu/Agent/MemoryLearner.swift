import Foundation
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

/// When memory learns (Android ADR-037, ADR-064): never mid-chat. It runs
/// - in a `BGProcessingTask` that asks for external power (while charging),
/// - opportunistically after a chat ends: when the conversation has been quiet
///   for a while in the foreground, or briefly when the user leaves the app,
/// - and when the user taps "Learn now" or adds a fact in the Memory screen.
/// A run stops between messages as soon as a chat turn needs the model.
@MainActor
final class MemoryLearner: ObservableObject {
    static let shared = MemoryLearner()
    static let taskIdentifier = "com.anu.app.memory.learn"

    @Published private(set) var isLearning = false
    @Published private(set) var lastRun: LearnResult?

    let store: MemoryStore
    /// The on-device model to learn with, or nil when none can run.
    var modelProvider: @MainActor () -> (any OnDeviceLanguageModel)?
    /// True while a chat turn or a headless request is using the model.
    var modelBusy: @MainActor () -> Bool
    /// How long a chat must be quiet before learning in the foreground.
    var quietPeriod: Duration = .seconds(90)

    private var run: Task<LearnResult, Never>?
    private var quietTimer: Task<Void, Never>?

    init(store: MemoryStore? = nil,
         modelProvider: (@MainActor () -> (any OnDeviceLanguageModel)?)? = nil,
         modelBusy: (@MainActor () -> Bool)? = nil) {
        self.store = store ?? .shared
        self.modelProvider = modelProvider ?? { AgentOrchestrator.shared.model as? any OnDeviceLanguageModel }
        self.modelBusy = modelBusy ?? { AgentOrchestrator.shared.isThinking }
    }

    // MARK: Running

    /// Learns from waiting messages, at most `maxEvents`. Only one run at a time.
    @discardableResult
    func learnNow(maxEvents: Int = .max) async -> LearnResult {
        if let run { _ = await run.value; return LearnResult(busy: true) }
        guard store.pendingCount > 0 else { return LearnResult() }
        guard let model = modelProvider() else {
            let result = LearnResult(noModel: true)
            lastRun = result
            return result
        }
        isLearning = true
        let store = self.store
        let busy = modelBusy
        let task = Task { @MainActor in
            await Self.process(store: store, model: model, maxEvents: maxEvents) { !busy() }
        }
        run = task
        let result = await task.value
        run = nil
        isLearning = false
        lastRun = result
        await store.indexVectors()
        return result
    }

    /// Stops a run between messages and waits for it, so a chat turn gets the
    /// model to itself. Instant when nothing is learning.
    func pause() async {
        quietTimer?.cancel()
        quietTimer = nil
        guard let run else { return }
        run.cancel()
        _ = await run.value
    }

    /// The core loop (tested directly): extract each waiting message on the
    /// on-device model, reconcile, and record failures (P6). The model's
    /// session is reset before and after, so a chat's cached context is never
    /// mixed with memory's prompts.
    static func process(store: MemoryStore, model: any OnDeviceLanguageModel, maxEvents: Int = .max,
                        today: Date = Date(), shouldContinue: @MainActor () -> Bool = { true }) async -> LearnResult {
        var result = LearnResult()
        let pending = store.pendingEvents(limit: maxEvents)
        guard !pending.isEmpty else { return result }
        do { try await model.load() } catch { result.noModel = true; return result }
        await model.resetSession()
        defer { Task { await model.resetSession() } }
        let extractor = FactExtractor(model: model, today: today, calendar: store.calendar)
        for event in pending {
            guard shouldContinue(), !Task.isCancelled else { break }
            switch await extractor.extract(event.content) {
            case .facts(let facts):
                result.processed += 1
                result.learned += store.learn(facts, from: event.id)
            case .failed:
                result.failed += 1
                store.markFailed(event.id)
            case .unavailable:
                // Not the message's fault (cancelled, or no GPU in the
                // background): it waits without using up an attempt.
                return result
            }
        }
        return result
    }

    // MARK: Opportunistic: after a chat ends

    /// A chat turn finished. If the chat then stays quiet, learn a little in
    /// the foreground; and make sure a charging-time run is scheduled.
    func turnEnded() {
        scheduleBackgroundLearning()
        quietTimer?.cancel()
        guard store.pendingCount > 0 else { return }
        let wait = quietPeriod
        quietTimer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, !self.modelBusy(), Self.deviceIsComfortable else { return }
            await self.learnNow(maxEvents: 3)
        }
    }

    /// The user left the app: a short run while iOS allows it, then the
    /// charging-time task picks up the rest.
    func appDidEnterBackground() {
        quietTimer?.cancel()
        scheduleBackgroundLearning()
        guard store.pendingCount > 0, !modelBusy(), Self.deviceIsComfortable else { return }
        #if os(iOS)
        var token = UIBackgroundTaskIdentifier.invalid
        token = UIApplication.shared.beginBackgroundTask(withName: "memory.learn") { [weak self] in
            Task { @MainActor in
                self?.run?.cancel()
                UIApplication.shared.endBackgroundTask(token)
            }
        }
        Task { @MainActor in
            await self.learnNow(maxEvents: 3)
            UIApplication.shared.endBackgroundTask(token)
        }
        #else
        Task { await self.learnNow(maxEvents: 3) }
        #endif
    }

    /// Not in Low Power Mode, and not hot.
    static var deviceIsComfortable: Bool {
        let info = ProcessInfo.processInfo
        #if os(iOS)
        if info.isLowPowerModeEnabled { return false }
        #endif
        return info.thermalState == .nominal || info.thermalState == .fair
    }

    // MARK: Background task (while charging)

    #if os(iOS)
    private static var registered = false

    /// Registers the processing task. Call before the app finishes launching.
    /// Skipped when Info.plist doesn't permit the identifier (registering an
    /// unlisted one is a crash).
    static func registerBackgroundTask() {
        guard !registered else { return }
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard permitted.contains(taskIdentifier) else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
            MainActor.assumeIsolated {
                MemoryLearner.shared.handle(task)
            }
        }
    }

    private func handle(_ task: BGTask) {
        let work = Task { @MainActor in await self.learnNow() }
        task.expirationHandler = { work.cancel(); Task { @MainActor in MemoryLearner.shared.run?.cancel() } }
        Task { @MainActor in
            let result = await work.value
            task.setTaskCompleted(success: !result.noModel)
            self.scheduleBackgroundLearning()
        }
    }
    #endif

    /// Asks iOS for a run while the phone is charging, if anything is waiting.
    func scheduleBackgroundLearning() {
        #if os(iOS)
        guard Self.registered, store.pendingCount > 0 else { return }
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }
}
