import Foundation

// The pure parts of reading a field and putting a result back (Android parity
// row 21; Android ADR-109 `KeyboardText`). The keyboard reads the field once,
// when an AI action is tapped, through UITextDocumentProxy — never while the
// user types.

/// What the field held around the cursor when the user tapped an AI action.
struct FieldText: Equatable, Sendable {
    var before: String
    var selected: String = ""

    init(before: String?, selected: String? = nil) {
        self.before = before ?? ""
        self.selected = selected ?? ""
    }
}

enum EditMode: String, Codable, Sendable {
    /// The result replaces the selection.
    case replaceSelection
    /// The result replaces `source`, the text just before the cursor.
    case replaceBefore
    /// The result goes in at the cursor, after `source`.
    case insert
}

/// Where a result goes. `source` is the text it replaces or follows, which must
/// still be there when the user taps to insert it; `input` is what the model
/// sees. `keep`: the selection stays and the result follows it (Continue, Emoji).
struct EditPlan: Equatable, Sendable, Codable {
    var mode: EditMode
    var source: String
    var input: String
    var keep: Bool = false

    /// The plan as hand-off metadata (`WritingHandoffRequest.meta`), and back.
    var meta: [String: String] { ["mode": mode.rawValue, "keep": keep ? "1" : "0"] }

    static func from(meta: [String: String], original: String) -> EditPlan? {
        guard let raw = meta["mode"], let mode = EditMode(rawValue: raw) else { return nil }
        return EditPlan(mode: mode, source: original,
                        input: original.trimmingCharacters(in: .whitespacesAndNewlines),
                        keep: meta["keep"] == "1")
    }
}

/// What to do to the field: delete this many characters before the cursor
/// (with `deleteBackward`), then insert this text (which replaces a selection).
struct KeyboardEdit: Equatable, Sendable {
    var deleteBefore: Int
    var insert: String
}

enum KeyboardText {
    /// How much text before the cursor is read: about a page, cut at a sentence
    /// so the model never starts mid-word. (iOS often hands a keyboard less.)
    static let readChars = 2_000
    /// The longest instruction the Ask field takes.
    static let askChars = WritingPrompt.maxInstructionChars

    private static let punctuationFirst: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "…", "'", "’"]

    /// The part of `before` that is offered: all of it, or when it filled the
    /// read, from its first sentence break.
    static func tail(_ before: String) -> String {
        guard before.count >= readChars else { return before }
        let text = Array(before.suffix(readChars))
        let limit = min(text.count, 400)
        for i in 0..<limit {
            if text[i] == "\n" || (".!?".contains(text[i]) && i + 1 < text.count && text[i + 1].isWhitespace) {
                return String(text[(i + 1)...])
            }
        }
        return String(text)
    }

    /// Improve, Shorter and the rest: the selection, or else the text before
    /// the cursor. Nil when there's nothing.
    static func forRewrite(_ field: FieldText) -> EditPlan? {
        if !isBlank(field.selected) {
            return EditPlan(mode: .replaceSelection, source: field.selected, input: trimmed(field.selected))
        }
        let t = tail(field.before)
        return isBlank(t) ? nil : EditPlan(mode: .replaceBefore, source: t, input: trimmed(t))
    }

    /// Continue: the next sentence after the text before the cursor, or after
    /// the selection, which it keeps.
    static func forContinue(_ field: FieldText) -> EditPlan? {
        if !isBlank(field.selected) {
            return EditPlan(mode: .replaceSelection, source: field.selected, input: trimmed(field.selected), keep: true)
        }
        let t = tail(field.before)
        return isBlank(t) ? nil : EditPlan(mode: .insert, source: t, input: trimmed(t))
    }

    /// Reply and Ask: text in the field is changed; an empty field gets new text at the cursor.
    static func forReply(_ field: FieldText) -> EditPlan {
        forRewrite(field) ?? EditPlan(mode: .insert, source: "", input: "")
    }

    static func forAsk(_ field: FieldText) -> EditPlan { forReply(field) }

    /// Emoji go after the text before the cursor, or after the selection, which stays.
    static func forEmoji(_ field: FieldText) -> EditPlan? { forContinue(field) }

    /// The text to commit for `result`: a replacement keeps the source's
    /// surrounding spaces, an addition gets a space where it needs one.
    static func output(_ plan: EditPlan, result: String) -> String {
        if plan.keep { return plan.source + join(plan.source, result) }
        if plan.mode == .insert { return join(plan.source, result) }
        return leading(plan.source) + result + trailing(plan.source)
    }

    /// The field edit for `result`.
    static func edit(_ plan: EditPlan, result: String) -> KeyboardEdit {
        let text = output(plan, result: result)
        switch plan.mode {
        case .replaceSelection, .insert: return KeyboardEdit(deleteBefore: 0, insert: text)
        case .replaceBefore: return KeyboardEdit(deleteBefore: plan.source.count, insert: text)
        }
    }

    /// `addition` as it follows `before`: with a space between words, none
    /// before punctuation or after a space.
    static func join(_ before: String, _ addition: String) -> String {
        guard let last = before.last, let first = addition.first else { return addition }
        if last.isWhitespace || first.isWhitespace || punctuationFirst.contains(first) { return addition }
        return " " + addition
    }

    /// Whether `plan` still fits the field as it is now. If the user typed or
    /// moved meanwhile, nothing is replaced.
    static func stillThere(_ plan: EditPlan, now: FieldText) -> Bool {
        switch plan.mode {
        case .replaceSelection: return now.selected == plan.source
        case .replaceBefore, .insert: return now.selected.isEmpty && now.before.hasSuffix(plan.source)
        }
    }

    /// A continuation that repeats the text it follows loses the repeat.
    static func withoutEcho(input: String, result: String) -> String {
        let text = trimmed(result)
        guard !input.isEmpty, text.hasPrefix(input) else { return text }
        return trimmed(String(text.dropFirst(input.count)))
    }

    /// The emoji in what the model wrote, each whole (skin tones, flags, joined
    /// families), without repeats: at most `max`.
    static func emoji(_ raw: String, max: Int) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;|"))
        var seen = Set<String>()
        var out: [String] = []
        for token in raw.components(separatedBy: separators) {
            let t = token.trimmingCharacters(in: CharacterSet(charactersIn: ".\"'"))
            guard isEmoji(t) else { continue }
            // Swift's Character is a grapheme cluster, so a run like "🎂🎉🥳"
            // splits into whole emoji: ZWJ sequences, skin tones, flags.
            for c in t {
                let e = String(c)
                if seen.insert(e).inserted { out.append(e) }
                if out.count == max { return out }
            }
        }
        return out
    }

    /// A token of emoji only: no letters or digits, and at least one symbol
    /// from the emoji ranges.
    static func isEmoji(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        var symbol = false
        for scalar in token.unicodeScalars {
            // Letters and digits fall to `default` and reject the token.
            switch scalar.value {
            case 0x200D, 0xFE0F, 0x20E3, 0x1F3FB...0x1F3FF, 0xE0020...0xE007F:
                continue
            case 0x1F000...0x1FAFF, 0x2600...0x27BF, 0x2B00...0x2BFF, 0x2190...0x21FF, 0x2300...0x23FF:
                symbol = true
            default:
                return false
            }
        }
        return symbol
    }

    /// The Ask field's text after one key: typed text (capped), or delete (one
    /// whole character, never half of one).
    static func askEdit(_ buffer: String, typed: String?, max: Int = askChars) -> String {
        if let typed { return String((buffer + typed).prefix(max)) }
        return buffer.isEmpty ? buffer : String(buffer.dropLast())
    }

    private static func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func leading(_ s: String) -> String { String(s.prefix { $0.isWhitespace }) }
    private static func trailing(_ s: String) -> String { String(s.reversed().prefix { $0.isWhitespace }.reversed()) }
}
