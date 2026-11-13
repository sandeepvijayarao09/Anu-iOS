import Foundation

// Voice turn-taking, ported from Anu Android's `core:voice` TurnTaking.kt
// (ADR-129). Everything here is plain logic on numbers and strings, so it runs
// in unit tests: the Simulator has no usable microphone, and the audio code
// that feeds these types (SpeechRecognizer, BargeInMonitor) stays thin.

// MARK: - Endpointer

/// When the user has finished speaking. Ends a listen sooner when what was
/// heard sounds finished, and waits the long pause only when it doesn't:
/// - after `quickMs` of quiet when the words end like a sentence and are three
///   or more, or are a whole one-word answer ("yes");
/// - after `midMs` when two words end like one ("call Maya"), since a thought
///   often goes on after two;
/// - after `slowMs` when they end mid-thought ("remind me to", "um") or are one
///   word that isn't a whole answer.
/// The word rules are English's; in another language every turn waits `slowMs`.
/// Quiet is measured from the later of the last loud level and the last change
/// in the words. Nothing ends before a word is heard.
struct Endpointer {
    static let quickMs = 700
    static let midMs = 1_100
    static let slowMs = 1_800

    let quickMs: Int
    let slowMs: Int
    /// The recognizer's language, as an ISO 639 code ("en", "eng", "hi").
    let language: String

    private var floor: Double = 1
    private var lastActive = -1
    private var words = ""

    init(quickMs: Int = Endpointer.quickMs, slowMs: Int = Endpointer.slowMs, language: String = "en") {
        self.quickMs = quickMs
        self.slowMs = slowMs
        self.language = language
    }

    /// The user's loudness from 0 to 1 at `now` (milliseconds).
    mutating func level(_ value: Double, now: Int) {
        floor = min(floor, value)
        if value >= floor + Self.loudAboveFloor, !words.trimmingCharacters(in: .whitespaces).isEmpty {
            lastActive = max(lastActive, now)
        }
    }

    /// The words heard so far.
    mutating func partial(_ text: String, now: Int) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, text != words else { return }
        words = text
        lastActive = max(lastActive, now)
    }

    /// When the user last spoke, or -1 before any word.
    var spokeAt: Int { lastActive }

    /// Whether the listen can end at `now`.
    func done(now: Int) -> Bool { lastActive >= 0 && now - lastActive >= wait() }

    /// How long a pause ends this turn, for what has been heard so far.
    func wait() -> Int { Self.waitFor(words, quickMs: quickMs, slowMs: slowMs, language: language) }

    enum Sounds: Equatable { case finished, unfinished }

    /// About 9 dB above the quietest level so far on a 60 dB scale.
    static let loudAboveFloor = 0.15

    static func knows(_ language: String) -> Bool { ["en", "eng"].contains(language.lowercased()) }

    static func waitFor(_ heard: String, quickMs: Int = quickMs, slowMs: Int = slowMs, language: String = "en") -> Int {
        if !knows(language) { return slowMs }
        if sounds(heard) == .unfinished { return slowMs }
        if words(heard).count == 2 { return max(quickMs, midMs) }
        return quickMs
    }

    static func sounds(_ heard: String) -> Sounds {
        let words = words(heard)
        guard let last = words.last else { return .unfinished }
        if words.count == 1 { return whole.contains(last) ? .finished : .unfinished }
        let pair = words.suffix(2).joined(separator: " ")
        return hanging.contains(last) || hangingPairs.contains(pair) ? .unfinished : .finished
    }

    static func words(_ heard: String) -> [String] {
        let lowered = heard.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let cleaned = lowered.unicodeScalars.map { scalar -> Character in
            let props = scalar.properties
            if props.isAlphabetic || props.numericType != nil || scalar == "'" || scalar == " " {
                return Character(scalar)
            }
            return " "
        }
        return String(cleaned).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Words that leave a sentence hanging when they come last.
    private static let hanging: Set<String> = [
        "and", "or", "but", "so", "because", "if", "then", "which", "when", "where", "while",
        "the", "a", "an", "my", "your", "his", "her", "their", "our", "its",
        "to", "of", "for", "with", "at", "on", "in", "into", "about", "from", "by", "as", "than",
        "is", "are", "was", "were", "what's", "whats", "what", "how", "i", "i'm", "um", "uh", "er", "erm", "hmm",
        "also", "plus", "let's", "between", "not", "more", "many", "much", "every", "each", "some", "any", "whose",
    ]

    /// Two last words that leave it hanging, though either can end a sentence alone.
    private static let hangingPairs: Set<String> = [
        "tell me", "give me", "remind me", "show me", "send me", "let me", "get me", "find me", "ask me",
        "what does", "how does", "when does", "where does", "why does", "what do", "how do", "where do", "why do", "when do",
        "how many", "how much", "what time",
    ]

    /// One-word turns that are whole answers.
    private static let whole: Set<String> = [
        "yes", "no", "yeah", "yep", "nope", "ok", "okay", "sure", "stop", "thanks", "cancel", "done", "send",
        "hi", "hello", "bye", "goodbye", "right", "correct", "exactly", "nothing", "never", "later", "now",
    ]
}

// MARK: - Barge-in

/// Whether the user is talking over Anu's own voice, from the echo-cancelled
/// microphone's loudness, one 20 ms chunk at a time.
/// - The first `calibrationChunks` chunks (1 s, which covers the synthesizer
///   starting to talk) learn how loud Anu's own voice still is after echo
///   cancellation: their 90th-percentile loudness, plus `margin`.
/// - Then `hold` of the last `window` chunks above it is the user. A loud word
///   of Anu's own is shorter than that, and where echo cancellation is weak the
///   bar sits above its own voice, so it fails quiet: no barge-in rather than a
///   false one.
struct BargeInDetector {
    /// 0.1 is 6 dB on the 60 dB level scale.
    static let margin = 0.1
    /// About -33 dBFS: quieter is the room, not someone talking to the phone.
    static let minLevel = 0.45
    /// One chunk is 20 ms of audio.
    static let chunkSeconds = 0.02

    let calibrationChunks: Int
    let window: Int
    let hold: Int

    private var calibration: [Double] = []
    private var recent: [Bool] = []

    /// The loudness the user must pass, once calibrated.
    private(set) var threshold: Double?
    /// Loudness of Anu's own voice heard back, once calibrated.
    private(set) var echo: Double = 0

    init(calibrationChunks: Int = 50, window: Int = 20, hold: Int = 16) {
        self.calibrationChunks = calibrationChunks
        self.window = window
        self.hold = hold
    }

    /// Takes one chunk's level and says whether the user is talking now.
    mutating func push(_ level: Double) -> Bool {
        guard let bar = threshold else {
            calibration.append(level)
            if calibration.count >= calibrationChunks {
                let sorted = calibration.sorted()
                echo = sorted[(sorted.count * 9) / 10]
                threshold = max(echo + Self.margin, Self.minLevel)
            }
            return false
        }
        recent.append(level >= bar)
        if recent.count > window { recent.removeFirst() }
        return recent.filter { $0 }.count >= hold
    }

    /// The level scale both detectors share: -60 dBFS or quieter is 0, full
    /// scale is 1.
    static func level(rms: Double) -> Double {
        guard rms > 0 else { return 0 }
        return min(max((20 * log10(rms) + 60) / 60, 0), 1)
    }
}

// MARK: - Spoken sentences

/// Cuts a streaming answer into pieces to speak. Markdown symbols are dropped,
/// because read aloud they are noise. Offsets are in UTF-16 units.
enum SpokenSentences {
    /// A clause must have this many words before it's spoken on its own; in
    /// Chinese or Japanese, twice as many characters.
    static let firstClauseWords = 5

    private static let end = regex("[.!?\u{2026}\u{0964}\u{061F}](?=\\s|$)|[\u{3002}\u{FF01}\u{FF1F}]|\\n")
    private static let clause = regex("[,;:\u{2014}\u{2013}\u{060C}](?=\\s)|[\u{3001}\u{FF0C}\u{FF1B}\u{FF1A}]")
    private static let markup = regex("[*_`#>]+")
    private static let link = regex("\\[([^\\]]+)\\]\\([^)]+\\)")
    private static let spaces = regex("\\s+")
    private static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "st", "vs", "e.g", "i.e", "jr", "sr", "prof", "approx"]

    /// The complete sentences in `text` after `from`, and where the next call
    /// should start. With `final`, whatever is left is a sentence too. With
    /// `first`, nothing has been spoken yet this turn, so a long first
    /// sentence's opening clause is spoken as soon as it's complete.
    static func next(_ text: String, from: Int, final: Bool, first: Bool = false) -> (sentences: [String], next: Int) {
        let ns = text as NSString
        var start = min(max(from, 0), ns.length)
        var sentences: [String] = []
        var search = start
        while search <= ns.length,
              let match = end.firstMatch(in: text, range: NSRange(location: search, length: ns.length - search)) {
            let stop = match.range.location + match.range.length
            if !endsSentence(ns, at: match.range.location) {
                search = stop
                continue
            }
            sentences.append(ns.substring(with: NSRange(location: start, length: stop - start)))
            start = stop
            search = start
        }
        if first, sentences.isEmpty, !final,
           let match = clause.firstMatch(in: text, range: NSRange(location: start, length: ns.length - start)),
           words(ns.substring(with: NSRange(location: start, length: match.range.location - start))) >= firstClauseWords {
            let stop = match.range.location + match.range.length
            sentences.append(ns.substring(with: NSRange(location: start, length: stop - start)))
            start = stop
        }
        if final, start < ns.length {
            sentences.append(ns.substring(from: start))
            start = ns.length
        }
        return (sentences.map(speakable).filter { !$0.isEmpty }, start)
    }

    /// A full stop after a list's number ("1. Milk") or a title ("Dr. Chen")
    /// doesn't end a sentence.
    private static func endsSentence(_ text: NSString, at: Int) -> Bool {
        guard text.character(at: at) == 0x2E else { return true } // "."
        var k = at
        while k > 0, !isWhitespace(text.character(at: k - 1)) { k -= 1 }
        let word = text.substring(with: NSRange(location: k, length: at - k))
        if abbreviations.contains(word.lowercased()) { return false }
        let lineStart = k == 0 || text.character(at: k - 1) == 0x0A
        return !(lineStart && (1...2).contains(word.count) && word.allSatisfy(\.isNumber))
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isWhitespace
    }

    private static func words(_ text: String) -> Int {
        let spoken = speakable(text)
        let wideCount = spoken.unicodeScalars.filter(isWide).count
        let narrow = String(String.UnicodeScalarView(spoken.unicodeScalars.filter { !isWide($0) }))
        return narrow.split(separator: " ").filter { !$0.isEmpty }.count + wideCount / 2
    }

    /// Chinese characters and Japanese kana, which are written without spaces.
    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x3040...0x30FF).contains(v) || (0x3400...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v)
    }

    static func speakable(_ text: String) -> String {
        var out = replace(link, in: text, with: "$1")
        out = replace(markup, in: out, with: "")
        out = replace(spaces, in: out, with: " ")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are literals checked by the unit tests.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }
}

/// Follows one assistant message as it streams and hands out the pieces to
/// speak, the first clause early (ADR-129), the rest sentence by sentence.
struct SpokenStream {
    private(set) var offset = 0
    private(set) var spokeAny = false
    /// The text this stream has consumed, so a message rewritten after it
    /// streamed (a settled answer) isn't spoken twice or out of order.
    private var consumed = ""
    private(set) var finished = false

    /// The pieces of `text` that are ready, given everything seen so far.
    mutating func feed(_ text: String, final: Bool) -> [String] {
        guard !finished else { return [] }
        // A tool call or other markup streams into the bubble before it is
        // replaced; never read it out. Wait for the settled text.
        if !final, Self.looksLikeMarkup(text) { return [] }
        if final, Self.looksLikeMarkup(text) { finished = true; return [] }
        // The message was rewritten under us: stop rather than re-speak.
        guard text.hasPrefix(consumed) else {
            finished = final
            return []
        }
        let (pieces, next) = SpokenSentences.next(text, from: offset, final: final, first: !spokeAny)
        offset = next
        consumed = (text as NSString).substring(to: next)
        if !pieces.isEmpty { spokeAny = true }
        if final { finished = true }
        return pieces
    }

    /// Raw tool-call output and code: things a voice shouldn't read.
    static func looksLikeMarkup(_ text: String) -> Bool {
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.hasPrefix("{") || head.hasPrefix("<") || head.hasPrefix("```")
            || head.contains("<|tool_call") || head.contains("\"tool\":")
    }
}

// MARK: - Voice pick

/// An installed speech voice, as `VoicePick` compares them.
struct TTSVoiceCandidate: Equatable {
    let identifier: String
    /// "en"
    let language: String
    /// "US"
    let country: String
    /// Higher is clearer (AVSpeechSynthesisVoiceQuality: 1 default, 2 enhanced, 3 premium).
    let quality: Int
}

/// The voice Anu speaks with: in the user's language, the country's own first,
/// then the clearest. Every system voice runs on the device.
enum VoicePick {
    static func best(_ voices: [TTSVoiceCandidate], language: String, country: String) -> TTSVoiceCandidate? {
        voices
            .filter { $0.language.caseInsensitiveCompare(language) == .orderedSame }
            .sorted { lhs, rhs in
                let lc = lhs.country.caseInsensitiveCompare(country) == .orderedSame
                let rc = rhs.country.caseInsensitiveCompare(country) == .orderedSame
                if lc != rc { return lc }
                if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
                return lhs.identifier < rhs.identifier
            }
            .first
    }
}
