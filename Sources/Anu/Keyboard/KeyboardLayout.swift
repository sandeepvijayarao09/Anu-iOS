import Foundation

// Anu's keyboard layouts (Android parity row 21; Android ADR-109): QWERTY with
// shift, two symbol pages, and number / phone pads. Pure data, so the layout
// is unit-tested and the keyboard extension only draws it.

/// One key. `weight` is its width in letter keys.
enum KeyboardKey: Equatable, Hashable, Sendable {
    case text(String, weight: Double = 1)
    case shift(weight: Double = 1.5)
    case backspace(weight: Double = 1.5)
    /// Switches pages: to symbols ("123"), more symbols ("#+=") or back to letters ("ABC").
    case page(KeyboardPage, label: String, weight: Double = 1.5)
    /// The next keyboard. Shown only when iOS says the keyboard needs one.
    case globe(weight: Double = 1)
    case space(weight: Double = 4)
    case enter(weight: Double = 1.75)
    /// Empty space in a row: the half-key inset the second letter row has.
    case gap(weight: Double = 0.5)

    var weight: Double {
        switch self {
        case .text(_, let w), .shift(let w), .backspace(let w), .page(_, _, let w),
             .globe(let w), .space(let w), .enter(let w), .gap(let w):
            return w
        }
    }
}

enum KeyboardPage: String, Sendable, Equatable {
    case letters, symbols, more
}

enum ShiftState: Sendable, Equatable {
    case off, once, locked
}

/// What the field's keyboard type asks for.
enum KeyboardLayoutKind: String, Sendable, Equatable {
    /// QWERTY (and its symbol pages).
    case letters
    /// The symbols page first, as iOS's numbers-and-punctuation keyboard opens.
    case symbolsFirst
    /// Digits with a decimal point.
    case numbers
    /// Digits with + * #.
    case phone
}

enum KeyboardLayout {
    private static func texts(_ row: String) -> [KeyboardKey] { row.map { .text(String($0)) } }

    private static func bottom(_ page: KeyboardPage, globe: Bool) -> [KeyboardKey] {
        var row: [KeyboardKey] = [page == .letters ? .page(.symbols, label: "123") : .page(.letters, label: "ABC")]
        if globe { row.append(.globe()) }
        row += [.space(), .enter()]
        return row
    }

    /// The rows of one page. `globe`: iOS's `needsInputModeSwitchKey`.
    static func rows(_ page: KeyboardPage, shift: ShiftState, globe: Bool = true) -> [[KeyboardKey]] {
        switch page {
        case .letters:
            let upper = shift != .off
            func cased(_ row: String) -> [KeyboardKey] { texts(upper ? row.uppercased() : row) }
            return [
                cased("qwertyuiop"),
                [.gap()] + cased("asdfghjkl") + [.gap()],
                [.shift()] + cased("zxcvbnm") + [.backspace()],
                bottom(page, globe: globe),
            ]
        case .symbols:
            return [
                texts("1234567890"),
                texts("-/:;()$&@\""),
                [.page(.more, label: "#+=")] + texts(".,?!'") + [.backspace()],
                bottom(page, globe: globe),
            ]
        case .more:
            return [
                texts("[]{}#%^*+="),
                texts("_\\|~<>€£¥•"),
                [.page(.symbols, label: "123")] + texts(".,?!'") + [.backspace()],
                bottom(page, globe: globe),
            ]
        }
    }

    /// Numbers and phone numbers get a pad.
    static func pad(_ kind: KeyboardLayoutKind, globe: Bool = true) -> [[KeyboardKey]] {
        let phone = kind == .phone
        func row(_ digits: String, _ last: KeyboardKey) -> [KeyboardKey] { texts(digits) + [last] }
        var bottom: [KeyboardKey] = []
        if globe { bottom.append(.globe()) }
        bottom += [.text(phone ? "#" : "."), .text("0"), .enter(weight: 1)]
        return [
            row("123", .text(phone ? "+" : "-")),
            row("456", .text(phone ? "*" : ",")),
            row("789", .backspace(weight: 1)),
            bottom,
        ]
    }

    /// The first page a field opens on.
    static func startPage(_ kind: KeyboardLayoutKind) -> KeyboardPage {
        kind == .symbolsFirst ? .symbols : .letters
    }

    /// Whether a field of this kind gets a pad instead of pages.
    static func usesPad(_ kind: KeyboardLayoutKind) -> Bool {
        kind == .numbers || kind == .phone
    }
}

/// Shift: a tap capitalizes the next letter, a quick second tap locks it, and
/// a typed letter releases a one-time shift.
enum ShiftRules {
    static let doubleTap: TimeInterval = 0.35

    static func tap(_ shift: ShiftState, sinceLastTap: TimeInterval) -> ShiftState {
        switch shift {
        case .off: return .once
        case .once: return sinceLastTap <= doubleTap ? .locked : .off
        case .locked: return .off
        }
    }

    static func afterText(_ shift: ShiftState) -> ShiftState { shift == .once ? .off : shift }

    /// The field's caps rule at the cursor turns a one-time shift on and off; it never touches a lock.
    static func auto(_ shift: ShiftState, capsNow: Bool) -> ShiftState {
        if shift == .locked { return .locked }
        return capsNow ? .once : .off
    }

    /// Whether a sentence-caps field wants a capital at the cursor, from the
    /// text before it: at the start, or after ". ", "! ", "? " or a new line.
    static func sentenceStart(_ before: String?) -> Bool {
        guard let before, !before.isEmpty else { return true }
        if before.last == "\n" { return true }
        let trimmed = before.reversed().drop { $0 == " " }
        guard trimmed.count < before.count, let mark = trimmed.first else { return false }
        return ".!?".contains(mark)
    }

    /// Whether a word-caps field wants a capital: at the start or after a space.
    static func wordStart(_ before: String?) -> Bool {
        guard let last = before?.last else { return true }
        return last == " " || last == "\n"
    }
}
