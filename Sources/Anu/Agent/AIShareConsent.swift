import Foundation
import Combine

// MARK: - Consent before sharing with a third-party AI (parity A9)
//
// App Store guideline 5.1.2(i): an app must say clearly when personal data
// goes to a third party, including a third-party AI, and get explicit
// permission first. Anu asks once per provider, before the first request
// leaves, on a sheet that names the provider and says what is sent. Nothing is
// sent until the user agrees; the answer is kept (date and wording version)
// and can be withdrawn in Settings → Privacy.
//
// Which destinations need it:
// - Google Gemini: yes, a third-party AI.
// - Your private compute server: yes. Anu can't tell who runs the server or
//   which model it forwards to, so it's treated as a third party.
// - Your Mac (Ollama): no. It's the user's own computer on their network.
// - Apple's Private Cloud Compute: no. It's the platform's own model, run by
//   Apple under Apple's privacy terms, not a third-party AI service.

/// A third-party AI that needs the user's agreement before Anu sends to it.
enum AIShareProvider: String, CaseIterable, Identifiable, Sendable, Codable {
    case gemini
    case privateServer

    var id: String { rawValue }

    /// Who receives the data, by name.
    var displayName: String {
        switch self {
        case .gemini: return "Google Gemini"
        case .privateServer: return "your private compute server"
        }
    }

    var title: String {
        switch self {
        case .gemini: return "Share with Google Gemini?"
        case .privateServer: return "Share with your private server?"
        }
    }

    /// Who runs it, for the sheet.
    var operatorLine: String {
        switch self {
        case .gemini:
            return "Gemini is Google's cloud AI. When a task is too big for this device, Anu can send it to Google to answer. Google's terms and privacy policy apply to what it receives."
        case .privateServer:
            return "Anu can send big tasks to the private compute server you set up. Whoever runs that server, and any model it uses, receives what is sent."
        }
    }

    /// Exactly what goes, for the sheet. Matches `PIISanitizer` and the
    /// escalation tools.
    static let whatIsSent = [
        "The task text, and a short summary of the chat when it's needed.",
        "Email addresses, phone numbers, street addresses, card numbers and ID numbers are replaced with placeholders first.",
        "Photos, PDFs, voice notes, your vault and your full memory are never sent.",
        "Each request is listed in Settings → Privacy, with exactly what was sent.",
    ]
}

/// The user's recorded answer for one provider.
struct AIShareConsentRecord: Codable, Equatable, Sendable {
    /// When the user agreed.
    let acceptedAt: Date
    /// Which wording of the sheet they agreed to.
    let version: Int
}

/// Where consent is kept: UserDefaults, as a date and a version number per
/// provider (no personal data). A new `currentVersion` asks again.
final class AIShareConsentStore: @unchecked Sendable {
    static let shared = AIShareConsentStore()
    static let currentVersion = 1

    private let defaults: UserDefaults
    private let lock = NSLock()
    /// Posted on the main queue when any provider's consent changes.
    static let didChange = Notification.Name("AIShareConsentStore.didChange")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static func key(_ provider: AIShareProvider) -> String { "ai_share_consent.\(provider.rawValue)" }

    func record(for provider: AIShareProvider) -> AIShareConsentRecord? {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: Self.key(provider)) else { return nil }
        return try? JSONDecoder().decode(AIShareConsentRecord.self, from: data)
    }

    func isGranted(_ provider: AIShareProvider) -> Bool {
        guard let record = record(for: provider) else { return false }
        return record.version >= Self.currentVersion
    }

    func grant(_ provider: AIShareProvider, at date: Date = Date()) {
        let record = AIShareConsentRecord(acceptedAt: date, version: Self.currentVersion)
        lock.lock()
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: Self.key(provider)) }
        lock.unlock()
        notify()
    }

    func revoke(_ provider: AIShareProvider) {
        lock.lock()
        defaults.removeObject(forKey: Self.key(provider))
        lock.unlock()
        notify()
    }

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }
}

/// What an egress funnel asks before it sends: "may this go to `provider`?".
protocol AIShareConsentGate: Sendable {
    func ensureConsent(_ provider: AIShareProvider) async -> Bool
}

/// The app's gate: yes if the user already agreed, else the sheet asks.
struct SystemAIShareConsentGate: AIShareConsentGate {
    var store: AIShareConsentStore = .shared

    func ensureConsent(_ provider: AIShareProvider) async -> Bool {
        if store.isGranted(provider) { return true }
        return await AIShareConsentCenter.shared.request(provider, store: store)
    }
}

/// A fixed answer, for tests and previews.
struct FixedAIShareConsentGate: AIShareConsentGate {
    let granted: Bool
    func ensureConsent(_ provider: AIShareProvider) async -> Bool { granted }
}

/// The text a tool returns when nothing was sent because consent is missing.
enum AIShareConsentText {
    static func notSent(_ provider: AIShareProvider) -> String {
        "Not sent: you haven't agreed to share requests with \(provider.displayName), so nothing left this device. You can agree the next time Anu asks, or in Settings → Privacy."
    }
}

/// Shows the consent sheet and waits for the answer. The sheet is attached
/// once at the app's root (`aiShareConsentSheet()`); with no sheet on screen
/// (a Siri or Shortcuts run), the answer is "no" straight away, so nothing is
/// sent without the user seeing the question.
@MainActor
final class AIShareConsentCenter: ObservableObject {
    static let shared = AIShareConsentCenter()

    struct Request: Identifiable, Equatable {
        let id = UUID()
        let provider: AIShareProvider
    }

    @Published private(set) var pending: Request?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var store: AIShareConsentStore = .shared
    /// How many on-screen views can show the sheet.
    private(set) var presenters = 0

    func attachPresenter() { presenters += 1 }
    func detachPresenter() { presenters = max(0, presenters - 1) }

    func request(_ provider: AIShareProvider, store: AIShareConsentStore = .shared) async -> Bool {
        if store.isGranted(provider) { return true }
        guard presenters > 0, pending == nil else { return false }
        self.store = store
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.pending = Request(provider: provider)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.answer(false) }
        }
    }

    /// The user's answer (or a dismissal, which is "no").
    func answer(_ agreed: Bool) {
        guard let request = pending else { return }
        if agreed { store.grant(request.provider) }
        pending = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: agreed)
    }
}
