import Foundation

// MARK: - Agent Skills (Anu Android ADR-120, after Google AI Edge Gallery)
//
// A skill is a folder with a `SKILL.md`: front matter between `---` lines that
// names and describes it, and a markdown body telling the model what to do,
// perhaps by running one of the folder's scripts with `run_js`. The model sees
// only the name and description until it calls `load_skill`.

/// One skill, parsed from its `SKILL.md`.
struct AgentSkill: Sendable, Equatable, Identifiable {
    enum Origin: String, Codable, Sendable {
        /// Shipped inside the app. Our own words.
        case builtIn
        /// Imported by the user from a file or a web address: someone else's
        /// words, so reading or running it taints the run (P4).
        case added
    }

    let name: String
    let description: String
    /// The whole `SKILL.md`, front matter and instructions, as `load_skill`
    /// returns it.
    let content: String
    /// The markdown body after the front matter.
    let instructions: String
    let origin: Origin
    /// The skill's script needs an API key or token (`require-secret`). Anu
    /// never hands secrets to a skill (I1), so such scripts aren't run.
    let requireSecret: Bool
    let homepage: String?
    /// The web address a user-added skill was downloaded from, if any.
    var source: String?

    var id: String { name }

    /// Someone else's words (P4).
    var untrusted: Bool { origin == .added }
}

/// Why a `SKILL.md` was refused. The messages are shown to the user on the
/// Skills page and read by tests, so they say exactly what is wrong.
struct SkillParseError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Reads a `SKILL.md`, as Anu Android's `SkillMd` and Gallery's SkillManager
/// do: `key: value` lines between two `---` lines, then the instructions.
enum SkillMd {
    static let fileName = "SKILL.md"
    /// Gallery's own limit for a skill file read from the web.
    static let maxBytes = 100_000
    static let maxDescription = 300
    static let maxNameLength = 64

    /// Lowercase words joined by hyphens, such as `qr-text`.
    private static let namePattern = try! NSRegularExpression(pattern: "^[a-z0-9]+(-[a-z0-9]+)*$") // swiftlint:disable:this force_try

    static func parse(_ text: String, origin: AgentSkill.Origin, source: String? = nil) throws -> AgentSkill {
        guard text.utf8.count <= maxBytes else {
            throw SkillParseError("a SKILL.md can be at most \(maxBytes / 1000) KB")
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            throw SkillParseError("a SKILL.md starts with a --- line")
        }
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            throw SkillParseError("a SKILL.md's front matter ends with a --- line")
        }

        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            } else if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast())
            }
            // The first spelling of a key wins, so a later line can't override it.
            if fields[key] == nil { fields[key] = value }
        }

        let name = fields["name"] ?? ""
        let range = NSRange(name.startIndex..., in: name)
        guard name.count <= maxNameLength,
              namePattern.firstMatch(in: name, range: range) != nil else {
            throw SkillParseError("a skill's name is lowercase words joined by hyphens, such as qr-text")
        }
        let description = (fields["description"] ?? "").trimmingCharacters(in: .whitespaces)
        guard !description.isEmpty else {
            throw SkillParseError("the skill \(name) has no description")
        }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw SkillParseError("the skill \(name) has no instructions after its front matter")
        }

        return AgentSkill(
            name: name,
            description: String(description.prefix(maxDescription)),
            content: normalized.trimmingCharacters(in: .whitespacesAndNewlines),
            instructions: body,
            origin: origin,
            requireSecret: fields["require-secret"]?.lowercased() == "true",
            homepage: fields["homepage"].flatMap { $0.isEmpty ? nil : $0 },
            source: source)
    }
}

// MARK: - Catalog

/// The skills the model can use: the turned-on built-in and added ones.
protocol SkillCatalog: Sendable {
    /// Turned-on skills only.
    func enabledSkills() -> [AgentSkill]
}

extension SkillCatalog {
    /// A turned-on skill by name, as Gallery matches it: case, hyphens,
    /// underscores and spaces don't count.
    func find(_ name: String) -> AgentSkill? {
        let wanted = SkillNames.normalized(name)
        guard !wanted.isEmpty else { return nil }
        return enabledSkills().first { SkillNames.normalized($0.name) == wanted }
    }
}

enum SkillNames {
    static func normalized(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}

/// A fixed list, for tests and previews.
struct StaticSkillCatalog: SkillCatalog {
    let skills: [AgentSkill]
    func enabledSkills() -> [AgentSkill] { skills }
}

// MARK: - Matching

/// The skills a message could mean (Anu Android ADR-131): those sharing a word
/// with it, by the skill's name, description or `## Examples`. Used to send a
/// message that names a skill down the agent path, which has the tools.
enum SkillMatch {
    static func matching(_ message: String, _ skills: [AgentSkill]) -> [AgentSkill] {
        let asked = words(message)
        guard !asked.isEmpty else { return [] }
        return skills.filter { skill in
            let named = Set(skill.name.split(separator: "-").map(String.init).filter { $0.count >= 2 })
            let told = Set(words(skill.description + " " + examples(skill.content)).map(stem))
            return asked.contains { named.contains($0) || told.contains(stem($0)) }
        }
    }

    private static func examples(_ content: String) -> String {
        guard let start = content.range(of: "## Examples") else { return "" }
        let rest = content[start.upperBound...]
        if let next = rest.range(of: "\n## ") { return String(rest[..<next.lowerBound]) }
        return String(rest)
    }

    private static func words(_ text: String) -> Set<String> {
        let tokens = text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        return Set(tokens.filter { ($0.count >= 4 && !generic.contains($0)) || (short.contains($0)) })
    }

    /// A crude stem, so "hashes" meets "hash" and "counting" meets "count".
    private static func stem(_ word: String) -> String {
        var w = word
        for suffix in ["ing", "ed", "es", "s"] where w.hasSuffix(suffix) && w.count > suffix.count + 2 {
            w.removeLast(suffix.count)
            break
        }
        return String(w.prefix(6))
    }

    private static let short: Set<String> = ["qr", "url", "sha", "md5"]

    private static let generic: Set<String> = [
        "given", "text", "user", "users", "when", "this", "that", "with", "your", "from", "what", "will", "wants",
        "want", "simple", "specific", "date", "into", "about", "some", "something", "them", "they", "their", "there",
        "here", "have", "show", "find", "make", "tell", "please", "could", "would", "should", "like", "just", "also",
        "each", "every", "where", "which", "while", "after", "before", "trigger", "says", "skill", "skills", "today",
        "tomorrow", "everyone", "world", "hello", "thanks", "example", "examples", "returns", "result", "answer",
    ]
}
