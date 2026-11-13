import AppIntents
import Foundation

// MARK: - Model-backed intents that may outlive Siri's 30 seconds (A6)
//
// A background intent normally gets about 30 seconds. Gemma on the phone can
// need longer for a page of text, so the writing intents and the inline
// answer conform to `LongRunningIntent` (iOS 27 / macOS 27). Its contract,
// from the SDK: do the work inside `performBackgroundTask(options:operation:)`
// and update `progress` regularly, or the system may end the extension.
// Progress here is tokens generated out of the token cap; `.requiresGPU`
// because the on-device model runs on the Metal GPU on a real phone.
//
// On iOS 17–26 the same intents run as before, inside the normal budget.

/// How long a model-backed intent may generate, and how much.
enum ModelIntentBudget {
    /// Under the classic budget: leave room for setup before ~30 s.
    static let standardTimeout: Duration = .seconds(25)
    /// With a long-running extension.
    static let longRunningTimeout: Duration = .seconds(180)

    static func timeout(longRunning: Bool) -> Duration {
        longRunning ? longRunningTimeout : standardTimeout
    }

    /// Token cap: a longer answer is only worth asking for when there's time to finish it.
    static func maxTokens(_ base: Int, longRunning: Bool) -> Int {
        longRunning ? base * 2 : base
    }

    /// True when this OS gives intents the long-running extension.
    static var longRunningAvailable: Bool {
        #if compiler(>=6.4)  // iOS 27 SDK APIs (Xcode 27)
        if #available(iOS 27.0, macOS 27.0, *) { return true }
        #endif
        return false
    }
}

/// An intent that answers with one headless generation on Anu's model.
protocol AnuModelIntent: ProgressReportingIntent {}

extension AnuModelIntent {
    /// Runs `completeHeadless` with progress, inside a long-running background
    /// task when the OS offers one.
    @MainActor
    func generate(system: String, user: String, maxTokens base: Int = 256) async throws -> String {
        let progress = self.progress
        var longRunning = false
        #if compiler(>=6.4)  // iOS 27 SDK APIs (Xcode 27)
        if #available(iOS 27.0, macOS 27.0, *) { longRunning = self is any LongRunningIntent }
        #endif
        let cap = ModelIntentBudget.maxTokens(base, longRunning: longRunning)
        let timeout = ModelIntentBudget.timeout(longRunning: longRunning)
        progress.totalUnitCount = Int64(cap)
        progress.completedUnitCount = 0
        progress.localizedDescription = "Writing with Anu"

        let work: () async -> String = {
            let text = await AgentOrchestrator.shared.completeHeadless(
                system: system, user: user, maxTokens: cap, timeout: timeout,
                onToken: { count in progress.completedUnitCount = Int64(min(count, cap)) })
            progress.completedUnitCount = progress.totalUnitCount
            return text
        }

        #if compiler(>=6.4)  // iOS 27 SDK APIs (Xcode 27)
        if longRunning, #available(iOS 27.0, macOS 27.0, *), let longRunningSelf = self as? any LongRunningIntent {
            return try await longRunningSelf.performBackgroundTask(options: [.requiresGPU], operation: work)
        }
        #endif
        return await work()
    }
}
