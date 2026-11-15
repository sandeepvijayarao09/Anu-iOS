import Foundation

// MARK: - Skill tools (ADR-120)
//
// Gallery's three skill tools, through the broker. `load_skill` and `run_js`
// stay on the phone (`read`); `run_intent` hands off to another app
// (`writeExternal`, always approved, behind Settings → Connectors' app-launch
// switch). Text from a skill someone else wrote, and anything a skill's script
// returns, taints the run (P4), so later outward actions in the turn ask first.

@MainActor
enum SkillTools {
    static func register(in registry: ToolRegistry, library: SkillLibrary = .shared) {
        registry.register(LoadSkillTool(catalog: library))
        registry.register(RunJSTool(library: library))
        registry.register(RunIntentTool(catalog: library))
    }

    /// The broker's answer when the model calls a skill as if it were a tool
    /// (Anu Android hit this on the S26: "make a QR code" called `qr-code`).
    static func notAToolMessage(_ called: String, registry: ToolRegistry) -> String? {
        guard let load = registry.tool(named: LoadSkillTool.toolName) as? LoadSkillTool,
              let skill = load.catalog.find(called) else { return nil }
        return "There is no tool named \(called). \(skill.name) is a skill: call \(LoadSkillTool.toolName) "
            + "with skill_name \"\(skill.name)\" first, then follow its instructions."
    }
}

// MARK: - load_skill

/// Puts a skill's whole `SKILL.md` into the model's context, so its
/// instructions arrive only when the request needs them. The description
/// lists every turned-on skill by name and description only.
struct LoadSkillTool: Tool {
    static let toolName = "load_skill"
    let name = LoadSkillTool.toolName
    let catalog: any SkillCatalog

    var description: String {
        let skills = catalog.enabledSkills()
        guard !skills.isEmpty else { return "Loads a skill. No skills are turned on." }
        var text = "Loads a skill's instructions. If the request matches one of these skills, call load_skill "
            + "with its name, then follow the instructions exactly, using run_js or run_intent as they say. "
            + "Don't call run_js or run_intent before loading the skill. Skills:"
        for skill in skills { text += "\n  - \"\(skill.name)\": \(skill.description)" }
        return text
    }

    var parameters: JSONSchema? {
        .object(
            description: "load_skill parameters",
            properties: ["skill_name": .string(description: "The name of the skill to load")],
            required: ["skill_name"])
    }

    func describe(_ arguments: JSONValue) -> String {
        let asked = ToolDescribing.text(arguments, "skill_name") ?? "a skill"
        return "Load the \(catalog.find(asked)?.name ?? asked) skill"
    }

    /// A skill the user added is someone else's words.
    func returnsUntrustedContent(for arguments: JSONValue) -> Bool {
        guard let asked = ToolDescribing.text(arguments, "skill_name") else { return false }
        return catalog.find(asked)?.untrusted ?? false
    }

    func execute(arguments: JSONValue) async throws -> String {
        let asked = ToolDescribing.text(arguments, "skill_name") ?? ""
        guard let skill = catalog.find(asked) else {
            let names = catalog.enabledSkills().map(\.name).joined(separator: ", ")
            throw ToolError.executionFailed("There is no skill named “\(asked)”. The skills are: \(names.isEmpty ? "none" : names)")
        }
        let payload: JSONValue = .object([
            "skill_name": .string(skill.name),
            "skill_instructions": .string(skill.content),
        ])
        return payload.canonicalJSON
    }
}

// MARK: - run_js

/// Runs one of a skill's scripts in `JSSandbox`: no network, no files, CPU and
/// time limits, data in as a string. Its result is a program's output, so it
/// taints the run (P4). Skills that need an API key aren't run (I1).
struct RunJSTool: Tool {
    static let toolName = "run_js"
    let name = RunJSTool.toolName
    let description = "Runs a script of a loaded skill, on this device with no network. Use only as the skill's instructions say."
    let library: SkillLibrary
    var sandbox = JSSandbox()

    var parameters: JSONSchema? {
        .object(
            description: "run_js parameters",
            properties: [
                "skill_name": .string(description: "The name of the skill"),
                "script_name": .string(description: "The script to run. Use 'index.js' if the skill doesn't name one"),
                "data": .untyped(description: "The data to pass to the script, usually a JSON string. Empty if none"),
            ],
            required: ["skill_name"])
    }

    func describe(_ arguments: JSONValue) -> String {
        let asked = ToolDescribing.text(arguments, "skill_name") ?? "a skill"
        let skill = library.find(asked)?.name ?? asked
        let data = Self.dataText(arguments["data"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return data.isEmpty ? "Run the \(skill) skill" : "Run the \(skill) skill with " + ToolDescribing.quoted(data)
    }

    /// The data as the script receives it: text as-is, anything else as JSON.
    static func dataText(_ value: JSONValue?) -> String {
        switch value {
        case nil, .null?: return ""
        case .string(let s)?: return s
        case let other?: return other.canonicalJSON
        }
    }

    func returnsUntrustedContent(for arguments: JSONValue) -> Bool { true }

    func execute(arguments: JSONValue) async throws -> String {
        let asked = ToolDescribing.text(arguments, "skill_name") ?? ""
        guard let skill = library.find(asked) else {
            throw ToolError.executionFailed("There is no skill named “\(asked)”. Load a skill with load_skill first.")
        }
        guard !skill.requireSecret else {
            throw ToolError.executionFailed("The \(skill.name) skill needs an API key, and Anu doesn't give keys to skills.")
        }
        let script = try library.script(for: skill, named: arguments["script_name"]?.stringValue ?? "")
        let data = Self.dataText(arguments["data"])
        let raw: String
        do {
            raw = try await sandbox.run(script: script, data: data)
        } catch {
            throw ToolError.executionFailed(error.localizedDescription)
        }
        return Self.read(raw)
    }

    /// The script's answer as Gallery reads it: `{result, error}` or plain text.
    static func read(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue,
              object["result"] != nil || object["error"] != nil else { return raw }
        var out: [String: JSONValue] = [:]
        if let result = object["result"], !result.isNull { out["result"] = result }
        if let error = object["error"], !error.isNull { out["error"] = error }
        if object["image"] != nil || object["webview"] != nil {
            out["note"] = .string("The skill made a picture or page, which Anu can't show in the chat yet. Tell the user it was made but can't be shown here.")
        }
        return JSONValue.object(out).canonicalJSON
    }
}

// MARK: - run_intent

/// Gallery's `run_intent` on iOS: hands a filled-in action to another app
/// through a URL scheme, which must be in Settings → Connectors' allowed
/// list. Nothing is sent by Anu; the user finishes in that app. Always asks
/// for the exact payload (I2) and is written to the privacy ledger.
struct RunIntentTool: Tool {
    static let toolName = "run_intent"
    let name = RunIntentTool.toolName
    let description = """
    Opens another app with an action filled in, as a skill's instructions say. Intents: \
    send_email {extra_email, extra_subject, extra_text}; send_sms {phone_number, sms_body}; \
    call_phone {phone_number}; open_maps {query}; open_url {url}. Parameters is a JSON object string.
    """
    static let intents = ["send_email", "send_sms", "call_phone", "open_maps", "open_url"]

    let catalog: any SkillCatalog
    var config: @Sendable () async -> AppLauncherConfig = { await ConnectorManager.shared.appConfig }
    var opener: any URLOpening = RunIntentTool.defaultOpener

    var parameters: JSONSchema? {
        .object(
            description: "run_intent parameters",
            properties: [
                "intent": .string(description: "The intent to run, such as send_email"),
                "parameters": .untyped(description: "A JSON object string with the intent's parameters"),
            ],
            required: ["intent"])
    }

    var sideEffect: ToolSideEffect { .external(capability: .appLaunch) }

    /// Unknown intents are reads that fail without asking: there is nothing to
    /// approve, and the answer tells the model what to do instead.
    func risk(for arguments: JSONValue) -> RiskTier {
        (try? url(for: arguments)) != nil ? .writeExternal : .read
    }

    func describe(_ arguments: JSONValue) -> String {
        let intent = ToolDescribing.text(arguments, "intent") ?? ""
        let p = Self.params(arguments)
        switch intent {
        case "send_email":
            let subject = p["extra_subject"].map { " " + ToolDescribing.quoted($0) } ?? ""
            return "Open an email to \(p["extra_email"] ?? "someone")\(subject) in Mail. Nothing is sent until you tap Send there"
        case "send_sms":
            let body = p["sms_body"].map { ": " + ToolDescribing.quoted($0) } ?? ""
            return "Open a text to \(p["phone_number"] ?? "someone") in Messages\(body). Nothing is sent until you tap Send there"
        case "call_phone":
            return "Call \(p["phone_number"] ?? "a number")"
        case "open_maps":
            return "Open Maps for " + ToolDescribing.quoted(p["query"] ?? "")
        case "open_url":
            return "Open " + (p["url"] ?? "a link")
        default:
            return "Run the intent \(intent)"
        }
    }

    func sendsTo(_ arguments: JSONValue) -> String? {
        guard ToolDescribing.text(arguments, "intent") == "open_url",
              let url = try? url(for: arguments) else { return nil }
        return url.host
    }

    func approvalNote(for arguments: JSONValue) -> String? {
        sendsTo(arguments) == nil ? "This hands off to another app" : nil
    }

    var editableFields: [EditableField] { [] }

    func execute(arguments: JSONValue) async throws -> String {
        let target = try url(for: arguments)
        let scheme = target.scheme?.lowercased() ?? ""
        guard await config().allows(scheme: scheme) else {
            return "The '\(scheme)' scheme isn't in the allowed list. Add it in Settings → Connectors."
        }
        await PrivacyLedger.shared.record(
            destination: .appLaunch(scheme: scheme, target: target.absoluteString),
            payload: target.absoluteString, redactions: 0)
        let ok = await opener.open(target)
        return ok ? "Opened \(target.absoluteString). The user finishes there." : "Couldn't open \(target.absoluteString)."
    }

    /// The URL an intent opens, built from checked parameters.
    func url(for arguments: JSONValue) throws -> URL {
        let intent = ToolDescribing.text(arguments, "intent") ?? ""
        let p = Self.params(arguments)
        func need(_ key: String) throws -> String {
            guard let value = p[key], !value.isEmpty else { throw ToolError.missingArgument(key) }
            return value
        }
        var components = URLComponents()
        switch intent {
        case "send_email":
            components.scheme = "mailto"
            components.path = try need("extra_email")
            components.queryItems = [("subject", p["extra_subject"]), ("body", p["extra_text"])]
                .compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
            if components.queryItems?.isEmpty == true { components.queryItems = nil }
        case "send_sms":
            let number = try Self.phone(need("phone_number"))
            let body = p["sms_body"].flatMap { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) }
            guard let url = URL(string: "sms:\(number)" + (body.map { "&body=\($0)" } ?? "")) else {
                throw ToolError.invalidArgument("phone_number", expected: "a phone number")
            }
            return url
        case "call_phone":
            guard let url = URL(string: "tel:" + (try Self.phone(need("phone_number")))) else {
                throw ToolError.invalidArgument("phone_number", expected: "a phone number")
            }
            return url
        case "open_maps":
            components.scheme = "maps"
            components.host = ""
            components.queryItems = [URLQueryItem(name: "q", value: try need("query"))]
        case "open_url":
            guard let url = URL(string: try need("url")), let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http", url.host != nil else {
                throw ToolError.invalidArgument("url", expected: "a web address starting with https://")
            }
            return url
        default:
            if let skill = catalog.find(intent) {
                throw ToolError.executionFailed("Intent not found. \(skill.name) is a skill: call load_skill with skill_name \"\(skill.name)\" first.")
            }
            throw ToolError.executionFailed("Unknown intent “\(intent)”. Use one of: \(Self.intents.joined(separator: ", ")).")
        }
        guard let url = components.url else { throw ToolError.executionFailed("Couldn't build the link") }
        return url
    }

    /// Digits and a leading +, so a number can't smuggle in URL syntax.
    private static func phone(_ raw: String) throws -> String {
        let kept = raw.filter { $0.isNumber || $0 == "+" }
        guard kept.count >= 3, !kept.dropFirst().contains("+") else {
            throw ToolError.invalidArgument("phone_number", expected: "a phone number")
        }
        return kept
    }

    /// `parameters`, given as a JSON string (Gallery) or an object, as text values.
    static func params(_ arguments: JSONValue) -> [String: String] {
        var object: [String: JSONValue] = [:]
        if let text = arguments["parameters"]?.stringValue, let data = text.data(using: .utf8),
           let decoded = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue {
            object = decoded
        } else if let decoded = arguments["parameters"]?.objectValue {
            object = decoded
        }
        var out: [String: String] = [:]
        for (key, value) in object {
            let text: String
            switch value {
            case .string(let s): text = s
            case .int(let i): text = String(i)
            case .double(let d): text = String(d)
            case .bool(let b): text = b ? "true" : "false"
            default: continue
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out[key] = trimmed }
        }
        return out
    }

    static var defaultOpener: any URLOpening {
        #if canImport(UIKit)
        return SystemURLOpener()
        #else
        return NoopURLOpener()
        #endif
    }
}
