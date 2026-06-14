import Foundation
import Combine

// MARK: - Egress destination

/// Where an outbound event went. The agent reaches outside the device through
/// exactly four channels; each is a case here. `leavesDevice` distinguishes a
/// true network egress (cloud / MCP / REST) from an on-device hand-off to
/// another app (app launch), which is still worth logging but never sends data
/// off the phone.
enum EgressDestination: Codable, Equatable, Sendable {
    case cloud(model: String)
    case mcpServer(name: String, host: String)
    case restHost(name: String, host: String)
    case appLaunch(scheme: String, target: String)

    /// Short human label, e.g. "Gemini (gemini-2.0-flash)" or "MCP · deepwiki".
    var displayName: String {
        switch self {
        case .cloud(let model): return "Gemini (\(model))"
        case .mcpServer(let name, _): return "MCP · \(name)"
        case .restHost(let name, _): return "REST · \(name)"
        case .appLaunch(let scheme, _): return "App launch · \(scheme)"
        }
    }

    /// Secondary detail line (the host or target).
    var detail: String {
        switch self {
        case .cloud: return "generativelanguage.googleapis.com"
        case .mcpServer(_, let host): return host
        case .restHost(_, let host): return host
        case .appLaunch(_, let target): return target
        }
    }

    var iconName: String {
        switch self {
        case .cloud: return "cloud"
        case .mcpServer: return "server.rack"
        case .restHost: return "network"
        case .appLaunch: return "app.badge"
        }
    }

    /// True when bytes actually left the device over the network.
    var leavesDevice: Bool {
        switch self {
        case .cloud, .mcpServer, .restHost: return true
        case .appLaunch: return false
        }
    }
}

// MARK: - Privacy event

/// One logged outbound event. `payloadSummary` is the (clipped) text that was
/// actually sent — for the cloud path this is the *sanitized* prompt, so the
/// ledger can prove what stayed private.
struct PrivacyEvent: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let timestamp: Date
    let turn: Int
    let destination: EgressDestination
    let payloadSummary: String
    let redactions: Int
    let byteCount: Int

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        turn: Int,
        destination: EgressDestination,
        payloadSummary: String,
        redactions: Int,
        byteCount: Int
    ) {
        self.id = id
        self.timestamp = timestamp
        self.turn = turn
        self.destination = destination
        self.payloadSummary = payloadSummary
        self.redactions = redactions
        self.byteCount = byteCount
    }
}

// MARK: - Per-turn summary (powers the chip)

/// Roll-up of one conversation turn's egress. A turn that ran but sent nothing
/// off-device yields `offDeviceCount == 0` / `byteCount == 0` — the green
/// "0 bytes left this device" state.
struct TurnEgressSummary: Equatable, Sendable {
    let turn: Int
    let offDeviceEvents: Int
    let onDeviceEvents: Int
    let redactions: Int
    let byteCount: Int
    let destinations: [EgressDestination]

    var nothingLeftDevice: Bool { offDeviceEvents == 0 }
}

// MARK: - Privacy Ledger

/// Logs every outbound event so the user can see exactly what left the device.
/// `@MainActor` so it serializes with the UI (no locks), mirroring
/// `ConversationStore`/`MemoryStore` persistence. Tool code (off the main actor)
/// records via `await PrivacyLedger.shared.record(...)`.
@MainActor
final class PrivacyLedger: ObservableObject {
    static let shared = PrivacyLedger()

    @Published private(set) var events: [PrivacyEvent] = []

    /// Increments once per conversation turn so events can be attributed and the
    /// chip can summarize "this turn". 0 means no turn has run yet.
    private(set) var currentTurn: Int = 0

    /// Cap matches `ConversationStore.maxStoredMessages` rationale — the UI only
    /// ever needs the recent past, and persistence stays bounded.
    static let maxEvents = 500

    private let store: PrivacyLedgerStore?
    private static let summaryClip = 300

    /// `shared` persists to Documents; tests pass `persists: false`.
    init(persists: Bool = true) {
        if persists, UserDefaults.standard.bool(forKey: "reset_privacy") {
            PrivacyLedgerStore().clear()
        }
        self.store = persists ? PrivacyLedgerStore() : nil
        if let saved = store?.load() {
            events = saved
            currentTurn = saved.map(\.turn).max() ?? 0
        }
    }

    /// Marks the start of a new conversation turn; returns the new turn id.
    @discardableResult
    func beginTurn() -> Int {
        currentTurn += 1
        return currentTurn
    }

    /// Records one outbound event against the current turn. `payload` is clipped
    /// to a preview; `byteCount` is the UTF-8 size of the *full* payload (what
    /// actually went over the wire).
    func record(destination: EgressDestination, payload: String, redactions: Int) {
        let event = PrivacyEvent(
            turn: currentTurn,
            destination: destination,
            payloadSummary: PrivacyLedger.clip(payload),
            redactions: redactions,
            byteCount: payload.utf8.count
        )
        events.append(event)
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
        store?.save(events)
    }

    func clear() {
        events.removeAll()
        store?.clear()
    }

    // MARK: - Derived views

    var eventsForCurrentTurn: [PrivacyEvent] {
        events.filter { $0.turn == currentTurn }
    }

    /// Summary of the most recent turn — `nil` until a turn has run. When a turn
    /// ran but sent nothing off-device, returns a zero-egress summary (drives the
    /// green chip).
    var lastTurnSummary: TurnEgressSummary? {
        guard currentTurn > 0 else { return nil }
        let turnEvents = eventsForCurrentTurn
        let offDevice = turnEvents.filter { $0.destination.leavesDevice }
        return TurnEgressSummary(
            turn: currentTurn,
            offDeviceEvents: offDevice.count,
            onDeviceEvents: turnEvents.count - offDevice.count,
            redactions: turnEvents.reduce(0) { $0 + $1.redactions },
            byteCount: offDevice.reduce(0) { $0 + $1.byteCount },
            destinations: turnEvents.map(\.destination)
        )
    }

    /// Whole-session roll-up for the Privacy screen header.
    var sessionTotals: (events: Int, offDevice: Int, redactions: Int, bytes: Int) {
        let offDevice = events.filter { $0.destination.leavesDevice }
        return (
            events.count,
            offDevice.count,
            events.reduce(0) { $0 + $1.redactions },
            offDevice.reduce(0) { $0 + $1.byteCount }
        )
    }

    private static func clip(_ text: String) -> String {
        text.count > summaryClip ? String(text.prefix(summaryClip)) + "…" : text
    }
}

// MARK: - Persistence

/// Tiny JSON-on-disk store for the ledger — same pattern as `ConversationStore`.
struct PrivacyLedgerStore {
    private let fileURL: URL

    init(directory: URL? = nil) {
        let dir = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("privacy_ledger.json")
    }

    func save(_ events: [PrivacyEvent]) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func load() -> [PrivacyEvent]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([PrivacyEvent].self, from: data)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
