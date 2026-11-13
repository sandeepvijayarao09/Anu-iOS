import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Apple's models: availability (pure, testable)
//
// Apple's on-device model (`SystemLanguageModel`) is Anu's Base tier when the
// device can run it, and Apple's Private Cloud Compute model
// (`PrivateCloudComputeLanguageModel`) the private cloud tier when the app has
// the managed entitlement and the user has quota left (parity A1). Everything
// the router and the Model screen need to know is reduced to `AppleModelStatus`
// here, so the decisions are unit-tested with fakes and never touch the
// framework. Anu drives both models through the iOS 27 `LanguageModel` API,
// so iOS/macOS 26 reports `.osTooOld` and Gemma carries the Base tier there.

/// Which of Apple's two models.
enum AppleModelKind: String, Sendable, Equatable {
    case onDevice
    case privateCloud

    var displayName: String {
        switch self {
        case .onDevice: return "Apple on-device"
        case .privateCloud: return "Apple Private Cloud Compute"
        }
    }
}

/// Why one of Apple's models can't run right now, in words the user can act on.
enum AppleModelUnavailableReason: Equatable, Sendable {
    /// Older than the OS Anu's Apple integration needs (iOS / macOS 27).
    case osTooOld
    /// This build or platform has no Foundation Models framework.
    case frameworkMissing
    /// The hardware can't run Apple Intelligence.
    case deviceNotEligible
    /// Apple Intelligence is turned off in Settings.
    case appleIntelligenceNotEnabled
    /// Apple's model is still downloading or preparing.
    case modelNotReady
    /// Private Cloud Compute isn't ready on this device yet.
    case systemNotReady
    /// The app hasn't been granted Apple's Private Cloud Compute entitlement.
    case notEntitled
    /// Today's Private Cloud Compute quota is used up.
    case quotaExhausted(resetDate: Date?)
    /// A recent request couldn't reach Apple; tried again after a short wait.
    case temporarilyUnreachable

    /// One sentence for the Model screen and error messages.
    var userText: String {
        switch self {
        case .osTooOld:
            return "Needs iOS 27 or macOS 27."
        case .frameworkMissing:
            return "Apple's models aren't available in this build."
        case .deviceNotEligible:
            return "This device can't run Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is off. Turn it on in Settings → Apple Intelligence & Siri."
        case .modelNotReady:
            return "Apple's model is still downloading. Try again later."
        case .systemNotReady:
            return "Private Cloud Compute isn't ready on this device yet."
        case .notEntitled:
            return "This build isn't approved for Apple's Private Cloud Compute yet."
        case .quotaExhausted(let reset):
            guard let reset else { return "Today's Private Cloud Compute limit is used up." }
            let time = DateFormatter.localizedString(from: reset, dateStyle: .none, timeStyle: .short)
            return "Today's Private Cloud Compute limit is used up. It resets at \(time)."
        case .temporarilyUnreachable:
            return "Couldn't reach Apple's Private Cloud Compute just now."
        }
    }
}

/// Whether one of Apple's models can take a request now.
enum AppleModelStatus: Equatable, Sendable {
    case available
    /// Usable, but close to today's limit (PCC only).
    case approachingLimit
    case unavailable(AppleModelUnavailableReason)

    var isUsable: Bool {
        switch self {
        case .available, .approachingLimit: return true
        case .unavailable: return false
        }
    }

    var reason: AppleModelUnavailableReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// Answers "can Apple's models run?". The system implementation asks the
/// framework; tests swap in a fake through `AppleModels.availability`.
protocol AppleModelAvailabilityChecking: Sendable {
    func status(of kind: AppleModelKind) -> AppleModelStatus
}

/// The process-wide checker. Settable so unit tests can fake Apple's models.
enum AppleModels {
    private static let checker = OSAllocatedUnfairLock<any AppleModelAvailabilityChecking>(
        initialState: SystemAppleModelAvailability())

    static var availability: any AppleModelAvailabilityChecking {
        get { checker.withLock { $0 } }
        set { checker.withLock { $0 = newValue } }
    }

    static func status(of kind: AppleModelKind) -> AppleModelStatus {
        availability.status(of: kind)
    }
}

// MARK: - Private Cloud Compute: entitlement and runtime back-off

/// Apple's PCC model needs a managed entitlement the developer applies for
/// (Docs/research/APPLE_SIRI_FOUNDATION_MODELS.md §2.2). Its key string isn't
/// published, so it can't be read back at runtime, and adding a guessed key to
/// `Anu.entitlements` would break signing. The owner sets the Info.plist flag
/// `AnuPrivateCloudComputeEntitled` to YES in the same change that adds the
/// granted entitlement; until then PCC stays off and the router skips it.
enum PrivateCloudEntitlement {
    static let infoPlistKey = "AnuPrivateCloudComputeEntitled"

    static func isGranted(bundle: Bundle = .main) -> Bool {
        (bundle.object(forInfoDictionaryKey: infoPlistKey) as? Bool) ?? false
    }
}

/// Remembers a PCC failure so the router stops choosing PCC until it can work
/// again: until the quota's reset date, or a few minutes after a network or
/// service failure. In memory plus UserDefaults (a date, not personal data).
final class PrivateCloudBackoff: @unchecked Sendable {
    static let shared = PrivateCloudBackoff()

    static let quotaKey = "apple_pcc_quota_until"
    static let unreachableKey = "apple_pcc_unreachable_until"
    /// How long PCC is skipped after a network or service failure.
    static let unreachableWait: TimeInterval = 5 * 60
    /// How long PCC is skipped after a quota error with no reset date.
    static let quotaWaitWithoutDate: TimeInterval = 60 * 60

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The reason PCC is being skipped at `now`, or nil when it may be tried.
    func reason(now: Date = Date()) -> AppleModelUnavailableReason? {
        lock.lock(); defer { lock.unlock() }
        if let until = defaults.object(forKey: Self.quotaKey) as? Date, until > now {
            return .quotaExhausted(resetDate: until)
        }
        if let until = defaults.object(forKey: Self.unreachableKey) as? Date, until > now {
            return .temporarilyUnreachable
        }
        return nil
    }

    func quotaReached(resetDate: Date?, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        defaults.set(resetDate ?? now.addingTimeInterval(Self.quotaWaitWithoutDate), forKey: Self.quotaKey)
    }

    func unreachable(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        defaults.set(now.addingTimeInterval(Self.unreachableWait), forKey: Self.unreachableKey)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: Self.quotaKey)
        defaults.removeObject(forKey: Self.unreachableKey)
    }
}

// MARK: - Base-tier choice (pure)

/// Which engine the Base tier uses for a model selection. Settings → Model
/// offers "Apple on-device", "Gemma 4" and "Automatic" (Apple when available,
/// else Gemma). Pure so the fallback rules are tested without either engine.
enum BaseTierEngine: Equatable, Sendable {
    case apple
    case gemma
    /// Nothing can run; the reason is shown as is.
    case unavailable(String)
}

enum BaseTierResolver {
    static func resolve(selection: ModelBackendKind, apple: AppleModelStatus, gemmaReady: Bool) -> BaseTierEngine {
        switch selection {
        case .appleOnDevice:
            if apple.isUsable { return .apple }
            return .unavailable("Apple on-device isn't available. \(apple.reason?.userText ?? "") Pick Gemma 4 or Automatic in Settings → Model.")
        case .automatic:
            if apple.isUsable { return .apple }
            return gemmaReady ? .gemma : .unavailable(UnavailableModel.defaultReason)
        case .liteRT, .downloadable:
            return gemmaReady ? .gemma : .unavailable(UnavailableModel.defaultReason)
        }
    }
}

// MARK: - The system checker

struct SystemAppleModelAvailability: AppleModelAvailabilityChecking {
    var entitlementGranted: @Sendable () -> Bool = { PrivateCloudEntitlement.isGranted() }
    var backoff: PrivateCloudBackoff = .shared

    func status(of kind: AppleModelKind) -> AppleModelStatus {
        #if canImport(FoundationModels)
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return .unavailable(.osTooOld) }
        switch kind {
        case .onDevice:
            return Self.map(SystemLanguageModel.default.availability)
        case .privateCloud:
            guard entitlementGranted() else { return .unavailable(.notEntitled) }
            if let skip = backoff.reason() { return .unavailable(skip) }
            let model = PrivateCloudComputeLanguageModel()
            switch model.availability {
            case .available: break
            case .unavailable(.deviceNotEligible): return .unavailable(.deviceNotEligible)
            case .unavailable: return .unavailable(.systemNotReady)
            }
            let quota = model.quotaUsage
            switch quota.status {
            case .limitReached: return .unavailable(.quotaExhausted(resetDate: quota.resetDate))
            case .belowLimit(let below): return below.isApproachingLimit ? .approachingLimit : .available
            @unknown default: return .available
            }
        }
        #else
        return .unavailable(.frameworkMissing)
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    static func map(_ availability: SystemLanguageModel.Availability) -> AppleModelStatus {
        switch availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled): return .unavailable(.appleIntelligenceNotEnabled)
        case .unavailable: return .unavailable(.modelNotReady)
        }
    }
    #endif
}
