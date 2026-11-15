import SwiftUI

// MARK: - Type scale
//
// Anu had drifted into using `.caption` (12pt) and `.caption2` (11pt) for
// roughly two thirds of all its text — endpoints, tool names, model specs,
// privacy detail — which left whole screens unreadable at a glance. These
// tokens replace that with a five-step scale where the step encodes intent, so
// "this is supporting copy" and "this is a timestamp" can't collapse onto the
// same size by accident.
//
// Every token is built on a SwiftUI *semantic* style rather than a fixed point
// size, so all of it scales with the reader's Dynamic Type setting. Fixed
// `.system(size:)` is still correct for SF Symbols — a button glyph shouldn't
// reflow — and is deliberately left alone.

extension Font {

    /// Screen and empty-state titles. One per screen.
    static let anuTitle = Font.title2.weight(.bold)

    /// Card titles, section headers, tool-call headers.
    static let anuHeading = Font.headline

    /// Primary content the user came to read: message text.
    static let anuBody = Font.body

    /// Supporting copy sitting under a title or heading.
    static let anuSecondary = Font.subheadline

    /// Labels, chips, list detail — small, but still meant to be read.
    /// This is the floor for anything load-bearing.
    static let anuLabel = Font.footnote

    /// A label carrying emphasis (a status word, an active count).
    static let anuLabelStrong = Font.footnote.weight(.semibold)

    /// Genuinely peripheral text — timestamps and nothing else. The only
    /// token below `anuLabel`, so reaching for it is a deliberate choice.
    static let anuMeta = Font.caption

    /// Hex digests, JSON payloads, raw tool output.
    static let anuCode = Font.system(.footnote, design: .monospaced)
}
