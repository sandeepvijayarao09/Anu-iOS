import Foundation

// What Anu's keyboard may do in one field (Android parity row 21; Android
// ADR-109, ADR-149), decided from the field's own traits alone: nothing typed
// is read to decide. Pure Foundation, so the iOS `UITextInputTraits` values
// arrive as their raw numbers and strings (the keyboard extension converts
// them; a unit test pins the raw values to UIKit's constants).
//
// iOS already gives secure fields and phone pads to the system keyboard, so a
// custom keyboard normally never sees them. The rules still cover them in case
// a host app reports traits unusually.

/// A field's traits, as raw `UITextInputTraits` values.
struct FieldTraits: Equatable, Sendable {
    /// `UIKeyboardType.rawValue`.
    var keyboardType: Int = FieldTraits.KeyboardType.default
    /// `UIReturnKeyType.rawValue`.
    var returnKeyType: Int = FieldTraits.ReturnKey.default
    /// `UITextAutocapitalizationType.rawValue`.
    var autocapitalization: Int = FieldTraits.Autocapitalization.sentences
    var isSecureTextEntry: Bool = false
    /// `UITextContentType.rawValue`, when the field declares one.
    var textContentType: String? = nil

    /// `UIKeyboardType` raw values.
    enum KeyboardType {
        static let `default` = 0, asciiCapable = 1, numbersAndPunctuation = 2, url = 3,
                   numberPad = 4, phonePad = 5, namePhonePad = 6, emailAddress = 7,
                   decimalPad = 8, twitter = 9, webSearch = 10, asciiCapableNumberPad = 11
    }

    /// `UIReturnKeyType` raw values.
    enum ReturnKey {
        static let `default` = 0, go = 1, google = 2, join = 3, next = 4, route = 5,
                   search = 6, send = 7, yahoo = 8, done = 9, emergencyCall = 10, `continue` = 11
    }

    /// `UITextAutocapitalizationType` raw values.
    enum Autocapitalization {
        static let none = 0, words = 1, sentences = 2, allCharacters = 3
    }

    /// `UITextContentType` raw values that mark a private field: passwords,
    /// one-time codes and payment card details. UIKit uses the HTML
    /// autocomplete tokens for cards ("cc-number", …); a unit test pins them.
    static let privateContentTypes: Set<String> = [
        "password", "new-password", "one-time-code",
        "cc-number", "cc-csc", "cc-exp", "cc-exp-month", "cc-exp-year",
        "cc-name", "cc-given-name", "cc-additional-name", "cc-family-name", "cc-type",
    ]

    /// `UITextContentType` raw values that want a pad.
    static let phoneContentTypes: Set<String> = ["tel"]
    static let numberContentTypes: Set<String> = ["postal-code"]
}

/// What the return key shows: a new line, or the field's own action.
enum EnterKeyKind: String, Sendable, Equatable {
    case newline, go, search, send, next, done, join, route, `continue`

    var label: String {
        switch self {
        case .newline: return "return"
        case .go: return "go"
        case .search: return "search"
        case .send: return "send"
        case .next: return "next"
        case .done: return "done"
        case .join: return "join"
        case .route: return "route"
        case .continue: return "continue"
        }
    }

    /// Whether the key is drawn as the accented action key.
    var isAction: Bool { self != .newline }
}

enum AutoCapsMode: String, Sendable, Equatable {
    case none, words, sentences, all
}

struct FieldPolicy: Equatable, Sendable {
    let layout: KeyboardLayoutKind
    /// A password, one-time code or card field: Anu reads nothing from it, not
    /// even for capitals, and offers no AI.
    let isPrivate: Bool
    /// Whether the AI strip is offered.
    let ai: Bool
    /// The field looks like a chat's (its return key is Send), so Reply leads.
    let chat: Bool
    let autoCaps: AutoCapsMode
    let enter: EnterKeyKind

    /// What the strip says instead of its actions, when it has no AI here.
    var stripNote: String? {
        if isPrivate { return "Private field. Anu reads nothing here." }
        if !ai { return "No AI in number fields." }
        return nil
    }

    static func of(_ traits: FieldTraits) -> FieldPolicy {
        typealias K = FieldTraits.KeyboardType
        let content = traits.textContentType
        let isPrivate = traits.isSecureTextEntry || content.map(FieldTraits.privateContentTypes.contains) == true

        let layout: KeyboardLayoutKind
        switch traits.keyboardType {
        case K.numberPad, K.asciiCapableNumberPad, K.decimalPad: layout = .numbers
        case K.phonePad: layout = .phone
        case K.numbersAndPunctuation: layout = .symbolsFirst
        default:
            if let content, FieldTraits.phoneContentTypes.contains(content) { layout = .phone }
            else { layout = .letters }
        }
        // Number, phone and number-and-punctuation fields get no AI; every other
        // field does (ADR-149), addresses and links too, since a browser's
        // address bar is also its search box.
        let pad = layout != .letters
            || content.map { FieldTraits.phoneContentTypes.contains($0) || FieldTraits.numberContentTypes.contains($0) } == true
        let ai = !isPrivate && !pad

        let enter = enterKey(traits.returnKeyType)
        let caps: AutoCapsMode
        if isPrivate || layout != .letters {
            caps = .none
        } else {
            switch traits.autocapitalization {
            case FieldTraits.Autocapitalization.words: caps = .words
            case FieldTraits.Autocapitalization.sentences: caps = .sentences
            case FieldTraits.Autocapitalization.allCharacters: caps = .all
            default: caps = .none
            }
        }
        return FieldPolicy(layout: layout, isPrivate: isPrivate, ai: ai,
                           chat: ai && enter == .send, autoCaps: caps, enter: enter)
    }

    private static func enterKey(_ raw: Int) -> EnterKeyKind {
        typealias R = FieldTraits.ReturnKey
        switch raw {
        case R.go: return .go
        case R.google, R.yahoo, R.search: return .search
        case R.send: return .send
        case R.next: return .next
        case R.done: return .done
        case R.join: return .join
        case R.route: return .route
        case R.continue: return .continue
        default: return .newline
        }
    }

    /// Whether the next letter should be a capital, from the field's caps mode
    /// and the text before the cursor. A private field is never read.
    func wantsCapital(before: String?) -> Bool {
        if isPrivate { return false }
        switch autoCaps {
        case .none: return false
        case .all: return true
        case .words: return ShiftRules.wordStart(before)
        case .sentences: return ShiftRules.sentenceStart(before)
        }
    }
}

/// What the keyboard last reported about itself, for Settings → Keyboard.
/// Written to the App Group only when the user allowed Full Access (without it
/// iOS gives a keyboard no shared container), and never holds typed text.
struct KeyboardStatus: Codable, Equatable, Sendable {
    var lastSeen: Date
    var hasFullAccess: Bool
    var appleModelAvailable: Bool
}

struct KeyboardStatusStore {
    private let file: AppGroupFile<KeyboardStatus>

    init(directory: URL = AppGroup.containerURL) {
        self.file = AppGroupFile("keyboard-status.json", directory: directory)
    }

    func load() -> KeyboardStatus? { file.load() }
    func save(_ status: KeyboardStatus) { file.save(status) }
}
