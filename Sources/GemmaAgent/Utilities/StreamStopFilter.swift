import Foundation

/// Streaming stop-sequence filter for engines that don't stop themselves
/// (the LiteRT engine generates past `<end_of_turn>` until maxTokens).
///
/// Feed chunks as they arrive; the filter returns the text that is safe to
/// emit, holding back any suffix that could still grow into a stop marker
/// (markers can be split across chunks). Once a full marker appears,
/// `finished` flips and everything from the marker onward is discarded.
struct StreamStopFilter {
    private let stops: [String]
    private var pending = ""
    private(set) var finished = false

    init(stopSequences: [String]) {
        self.stops = stopSequences.filter { !$0.isEmpty }
    }

    /// Process the next chunk; returns text safe to emit now.
    mutating func process(_ chunk: String) -> String {
        guard !finished else { return "" }
        pending += chunk

        // Complete stop marker present → emit what precedes it, stop.
        for stop in stops {
            if let range = pending.range(of: stop) {
                finished = true
                let out = String(pending[..<range.lowerBound])
                pending = ""
                return out
            }
        }

        // Hold back the longest suffix that is a prefix of any stop marker.
        var holdback = 0
        for stop in stops {
            let maxLen = min(stop.count - 1, pending.count)
            guard maxLen > 0 else { continue }
            for len in stride(from: maxLen, through: 1, by: -1) {
                if pending.hasSuffix(String(stop.prefix(len))) {
                    holdback = max(holdback, len)
                    break
                }
            }
        }

        let out = String(pending.dropLast(holdback))
        pending = String(pending.suffix(holdback))
        return out
    }
}
