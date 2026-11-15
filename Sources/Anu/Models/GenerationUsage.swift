import Foundation

/// What one generation read and wrote, as the backend measured it (ADR-071).
///
/// Token counts are the runtime's own when `counted` is true; otherwise the
/// caller fills in calibrated estimates. Times are by the device's clock, from
/// when the request reached the backend.
struct GenerationUsage: Sendable, Equatable {
    /// Tokens the model read for this turn (the part of the prompt it prefilled).
    var promptTokens: Int?
    /// Tokens the model wrote, reasoning included.
    var outputTokens: Int?
    /// True when the counts above came from the runtime, not an estimate.
    var counted: Bool = false
    /// Where it ran, such as "GPU" or "CPU".
    var backend: String?
    /// The reasoning channel's text, when thinking was on and the model used it.
    var thought: String?
    /// How long the model reasoned before its answer began.
    var thoughtMs: Int?
    /// From the request to the first piece of output (reasoning or answer).
    var firstOutputMs: Int?
    /// From the first piece of output to the last.
    var decodeMs: Int?
}

/// The "Think before answering" switch (ADR-077). Off by default: thinking
/// delays the first word a lot on a phone, so it's the user's choice.
enum ThinkingSetting {
    static let key = "thinking_enabled"
}
