import Foundation

/// Chooses which tools the agent prompt offers this turn, within a token
/// budget (Android: tools are offered when a turn needs them, ADR-114).
///
/// Seen on the iPhone 2026-11-13: offering all 29 registered tools made the
/// agent prompt about 4,200 tokens, over the 4,096-token engine Anu had then
/// (now 8,192, `LiteRTLMModel.contextTokens`), so every agent turn failed
/// with "Input token ids are too long". Now a turn
/// gets a small core set plus the tools its words point at, cheapest-first
/// once relevance ties, until the budget is used.
enum ToolSelector {
    /// Tokens the tool section of the prompt may use.
    static let budgetTokens = 1_300
    /// Always offered: cheap and useful to almost any agent turn.
    static let core = ["datetime", "calculator"]

    /// Words that point at a tool, beyond its own name and description.
    static let triggers: [String: [String]] = [
        "set_timer": ["timer", "alarm", "wake", "minutes", "minute", "seconds", "hour", "hours"],
        "reminders": ["remind", "reminder", "reminders", "todo", "to-do", "list", "shopping", "grocery", "groceries"],
        "calendar": ["calendar", "schedule", "meeting", "meetings", "appointment", "event", "events", "free", "busy", "agenda"],
        "contacts": ["contact", "contacts", "number", "phone", "email", "address", "birthday"],
        "contact_action": ["call", "text", "message", "email", "facetime", "phone", "dial", "ring"],
        "phone_flashlight": ["flashlight", "torch", "light"],
        "phone_brightness": ["brightness", "bright", "brighter", "dim", "dimmer", "screen"],
        "phone_navigate": ["directions", "navigate", "route", "drive", "walk", "nearest", "near", "way"],
        "phone_open_app": ["open", "launch", "app"],
        "open_app": ["open", "launch", "app", "play", "music", "maps"],
        "phone_share": ["share"],
        "run_shortcut": ["shortcut", "shortcuts", "automation", "routine"],
        "web_search": ["search", "latest", "news", "current", "weather", "price", "prices", "score", "look", "google"],
        "photos": ["photo", "photos", "picture", "pictures", "album", "library", "selfie"],
        "files": ["file", "files", "save", "note", "notes", "document"],
        "read_pdf": ["pdf", "document"],
        "read_text": ["read", "aloud", "text"],
        "generate_image": ["image", "draw", "drawing", "picture", "illustration", "generate"],
        "unit_converter": ["convert", "km", "miles", "mile", "kg", "pounds", "lbs", "celsius", "fahrenheit", "inches", "cm", "liters", "gallons"],
        "clipboard": ["copy", "paste", "clipboard", "copied"],
        "keep_awake": ["awake", "sleep", "lock"],
        "load_skill": ["skill", "skills", "hash", "sha", "qr"],
        // Anu's own notes (ADR-093); a grocery list is a note (ADR-119).
        "notes_add": ["note", "notes", "jot", "idea", "ideas", "grocery", "groceries"],
        "notes_search": ["note", "notes", "find"],
        "notes_list": ["note", "notes"],
        "memory_remember": ["remember", "memorize", "mind", "noted"],
        "memory_search": ["remember", "recall", "know", "memory", "memories", "told"],
        "memory_forget": ["forget", "erase", "memory", "memories", "forgotten"],
    ]

    /// Tools offered together (a skill's scripts run in the turn it's loaded).
    static let companions: [String: [String]] = ["load_skill": ["run_js", "run_intent"]]

    /// The tools for this turn. `turns` are the user's messages, newest last.
    /// `escalation` is the active cloud provider's escalation tool, if any.
    static func select(_ all: [any Tool], turns: [String], escalation: String?,
                       budget: Int = budgetTokens) -> [any Tool] {
        let byName = Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let latest = words(turns.last ?? "")
        let earlier = words(turns.dropLast().suffix(2).joined(separator: " "))

        var scored: [(tool: any Tool, score: Int, cost: Int)] = []
        for tool in all where !core.contains(tool.name) && !tool.name.hasPrefix("escalate_to_") {
            guard !isCompanion(tool.name) else { continue }
            let keys = keywords(for: tool)
            let score = 3 * latest.intersection(keys).count + earlier.intersection(keys).count
            if score > 0 { scored.append((tool, score, cost(tool))) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.cost < $1.cost }

        var chosen: [any Tool] = core.compactMap { byName[$0] }
        if let escalation, let tool = byName[escalation] { chosen.append(tool) }
        var used = chosen.reduce(0) { $0 + cost($1) }
        for entry in scored {
            let group = [entry.tool] + (companions[entry.tool.name] ?? []).compactMap { byName[$0] }
            let groupCost = group.reduce(0) { $0 + cost($1) }
            guard used + groupCost <= budget else { continue }
            chosen += group
            used += groupCost
        }
        return chosen
    }

    /// The smallest useful set, for a retry after the engine said the prompt
    /// was too long.
    static func minimal(_ all: [any Tool]) -> [any Tool] {
        all.filter { core.contains($0.name) }
    }

    /// Estimated tokens a tool adds to the prompt (its rendered spec).
    static func cost(_ tool: any Tool) -> Int {
        let chars = GemmaChatTemplate.toolProtocolBlock(tools: [tool]).count
            - GemmaChatTemplate.toolProtocolBlock(tools: []).count
        return max(1, Int((Double(max(chars, 0)) / 3.5).rounded(.up)))
    }

    private static func isCompanion(_ name: String) -> Bool {
        companions.values.contains { $0.contains(name) }
    }

    private static func keywords(for tool: any Tool) -> Set<String> {
        var keys = Set(tool.name.lowercased().split { $0 == "_" || $0 == "-" }.map(String.init).filter { $0.count >= 3 })
        keys.formUnion(words(tool.description).filter { $0.count >= 5 && !stopwords.contains($0) })
        keys.formUnion(triggers[tool.name] ?? [])
        return keys
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "-") }.map(String.init))
    }

    private static let stopwords: Set<String> = [
        "about", "using", "which", "their", "there", "these", "those", "would", "could", "should", "other",
        "returns", "return", "given", "where", "while", "after", "before", "user's", "users", "tool", "tools",
        "anything", "something", "current", "optional", "required", "string", "number", "value", "values",
    ]
}
