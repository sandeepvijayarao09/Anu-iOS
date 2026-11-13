import Foundation

/// What "About this answer" shows (ADR-071), saved with each answer: which
/// model answered and where, what it was given and did, and how fast it was.
/// It keeps references and numbers, never content: the count of memory notes,
/// tools by name, destinations by name. The receipts stay on the message.
///
/// Every field but `tier` and `modelName` is optional so details saved by a
/// later build still decode, and messages saved before details existed simply
/// have none (`AgentMessage.details == nil`).
struct AnswerDetails: Codable, Sendable, Equatable {
    enum Tier: String, Codable, Sendable {
        /// The on-device model (Gemma 4 on LiteRT-LM, or whatever is active).
        case onDevice
        /// Google Gemini, in the cloud.
        case cloud
        /// The user's own private compute server.
        case privateCloud
        /// Apple's Private Cloud Compute model (parity A1).
        case applePrivateCloud
    }

    var tier: Tier
    /// The model that answered, as its backend names itself.
    var modelName: String
    /// Where an on-device model ran, such as "GPU" or "CPU".
    var backend: String?
    /// The path the router chose: "Chat", "Agent", "Planner" or "Cloud".
    var route: String?
    /// The tier that tried first, when an on-device turn handed off to the cloud.
    var escalatedFrom: Tier?
    /// How many memory notes were in the prompt (0 when memory wasn't used).
    var memoryNotes: Int?
    /// The tools the broker ran this turn, by name, in order.
    var toolsUsed: [String]?
    /// Where anything went that left the device, by display name (from the
    /// Privacy Ledger). Empty when nothing left.
    var destinations: [String]?
    /// From sending until the answer's first word, by the device's clock.
    var firstWordMs: Int?
    /// From sending until the answer was complete.
    var totalMs: Int?
    /// What the on-device model read and wrote this turn, over all its steps.
    var tokensIn: Int?
    var tokensOut: Int?
    /// Time spent writing those output tokens (first piece to last, summed).
    var writeMs: Int?
    /// Time to the first piece of output, summed over steps (reading time).
    var readMs: Int?
    /// True when the token counts are the runtime's own, false when estimates.
    var counted: Bool?
    /// How long the model reasoned before its answer began (ADR-077).
    var thoughtMs: Int?
    /// When the answer was completed.
    var completedAt: Date?

    /// Output tokens a second, when it can be worked out.
    var writeRate: Double? { Self.rate(tokensOut, writeMs) }
    /// Prompt tokens a second (prefill), when it can be worked out.
    var readRate: Double? { Self.rate(tokensIn, readMs) }

    var leftDevice: Bool { tier != .onDevice || !(destinations ?? []).isEmpty }

    static func rate(_ tokens: Int?, _ ms: Int?) -> Double? {
        guard let tokens, tokens > 0, let ms, ms > 0 else { return nil }
        return Double(tokens) * 1000 / Double(ms)
    }
}

// MARK: - Wording (kept apart from the view so it's unit tested)

enum AnswerDetailsText {
    /// The caption under an answer: the model that answered.
    static func caption(_ d: AnswerDetails) -> String {
        switch d.tier {
        case .onDevice: return "On device · \(shortModelName(d.modelName))"
        case .cloud: return "Cloud · Gemini"
        case .privateCloud: return "Private Compute"
        case .applePrivateCloud: return "Apple Private Cloud Compute"
        }
    }

    /// The sheet's first line: where the user's data went for this answer.
    static func whereItWent(_ d: AnswerDetails) -> String {
        switch d.tier {
        case .cloud: return "Sent to Gemini (Google)"
        case .privateCloud: return "Sent to your private compute server"
        case .applePrivateCloud: return "Sent to Apple's Private Cloud Compute (nothing kept)"
        case .onDevice:
            let places = d.destinations ?? []
            if places.isEmpty { return "Nothing left your device" }
            let items = places.count == 1 ? "1 item" : "\(places.count) items"
            var seen = Set<String>()
            let distinct = places.filter { seen.insert($0).inserted }
            return "\(items) left your device · to \(joinAnd(distinct))"
        }
    }

    /// The second line: which model answered, and where it ran.
    static func whoAnswered(_ d: AnswerDetails) -> String {
        switch d.tier {
        case .cloud: return "Gemini · in the cloud"
        case .privateCloud: return "Your private compute server"
        case .applePrivateCloud: return "Apple's Private Cloud Compute model · on Apple's servers"
        case .onDevice:
            let place = d.backend.map { "\($0), on this device" } ?? "on this device"
            return "\(shortModelName(d.modelName)) · \(place)"
        }
    }

    /// The memory line, when memory was in the prompt.
    static func memory(_ d: AnswerDetails) -> String? {
        guard let n = d.memoryNotes, n > 0 else { return nil }
        return n == 1 ? "Used 1 note from Memory" : "Used \(n) notes from Memory"
    }

    /// How fast it was, as rows: times from the clock, rates marked when estimated.
    static func speedRows(_ d: AnswerDetails) -> [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if let t = d.thoughtMs { rows.append(("Thinking", seconds(t))) }
        if let t = d.firstWordMs { rows.append(("First word", seconds(t))) }
        if d.tier == .onDevice {
            let counted = d.counted ?? false
            if let r = d.readRate { rows.append(("Reading", perSecond(r, counted: counted))) }
            if let r = d.writeRate { rows.append(("Writing", perSecond(r, counted: counted))) }
            if let i = d.tokensIn, let o = d.tokensOut {
                rows.append(("Tokens", "\(counted ? "" : "about ")\(i) in · \(o) out"))
            }
        }
        if let t = d.totalMs { rows.append(("Total", seconds(t))) }
        return rows
    }

    /// "Gemma 4 E4B (LiteRT-LM)" → "Gemma 4 E4B".
    static func shortModelName(_ name: String) -> String {
        guard let paren = name.range(of: " (") else { return name }
        return String(name[..<paren.lowerBound])
    }

    static func perSecond(_ rate: Double, counted: Bool) -> String {
        let value = rate >= 10 ? String(Int(rate.rounded())) : String(format: "%.1f", rate)
        return counted ? "\(value) tokens/s" : "about \(value) tokens/s"
    }

    static func seconds(_ ms: Int) -> String {
        if ms < 10_000 { return String(format: "%.1f s", Double(ms) / 1000) }
        if ms < 60_000 { return "\(Int((Double(ms) / 1000).rounded())) s" }
        return "\(ms / 60_000) min \((ms % 60_000) / 1000) s"
    }

    static func joinAnd(_ items: [String]) -> String {
        guard items.count > 1 else { return items.joined() }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
}
