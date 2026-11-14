import Foundation

/// A single resolved contact.
struct ContactMatch: Sendable, Equatable {
    let name: String
    let phones: [String]
    let emails: [String]
}

/// Resolves a contact name to matching people. Injectable so the call/text/email
/// tool is unit-testable without touching the address book. Returns ALL matches
/// so the tool can disambiguate rather than silently guess.
protocol ContactResolving: Sendable {
    func resolve(name: String) async -> [ContactMatch]
}

#if canImport(Contacts)
import Contacts
/// Looks up contacts via the address book — the same Contacts permission the
/// read-only `contacts` tool already uses (no new entitlement).
struct SystemContactResolver: ContactResolving {
    func resolve(name: String) async -> [ContactMatch] {
        let store = CNContactStore()
        let granted: Bool = await withCheckedContinuation { cont in
            store.requestAccess(for: .contacts) { ok, _ in cont.resume(returning: ok) }
        }
        guard granted else { return [] }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey,
                    CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matchingName: name)
        guard let matches = try? store.unifiedContacts(matching: predicate, keysToFetch: keys) else {
            return []
        }
        return matches.map { c in
            let full = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            return ContactMatch(
                name: full.isEmpty ? "(no name)" : full,
                phones: c.phoneNumbers.map { $0.value.stringValue },
                emails: c.emailAddresses.map { String($0.value) })
        }
    }
}
#endif

/// One-step "call dad" / "text mom" / "email Sarah": resolves the contact (or a
/// raw number/email) and opens the matching URL (tel:/sms:/mailto:). Outward
/// action — gated by confirmation and the app-launch capability + scheme list.
struct ContactActionTool: Tool {
    let name = "contact_action"
    let description = """
    Reach someone in one step. 'action' is 'call', 'text', 'email', 'facetime' (video), \
    or 'facetime_audio'. 'contact' is a person's name (looked up in Contacts) or a raw \
    phone number / email. 'message' is the optional text/email body; 'subject' an optional \
    email subject.
    """

    let resolver: any ContactResolving
    let opener: any URLOpening
    let appConfig: AppLauncherConfig

    init(resolver: any ContactResolving, opener: any URLOpening, appConfig: AppLauncherConfig) {
        self.resolver = resolver
        self.opener = opener
        self.appConfig = appConfig
    }

    var parameters: JSONSchema? {
        .object(
            description: "Contact action parameters",
            properties: [
                "action": .string(description: "call, text, email, facetime, or facetime_audio",
                                   enumValues: ["call", "text", "email", "facetime", "facetime_audio"]),
                "contact": .string(description: "Name to look up, or a raw phone number / email"),
                "message": .string(description: "Optional body for a text or email"),
                "subject": .string(description: "Optional subject for an email"),
            ],
            required: ["action", "contact"]
        )
    }

    var sideEffect: ToolSideEffect { .external(capability: .appLaunch) }

    func execute(arguments: JSONValue) async throws -> String {
        let action = (arguments["action"]?.stringValue ?? "").lowercased()
        guard ["call", "text", "email", "facetime", "facetime_audio"].contains(action) else {
            throw ToolError.invalidArgument("action", expected: "'call', 'text', 'email', 'facetime', or 'facetime_audio'")
        }
        guard let contact = arguments["contact"]?.stringValue, !contact.isEmpty else {
            throw ToolError.missingArgument("contact")
        }
        let message = arguments["message"]?.stringValue
        let subject = arguments["subject"]?.stringValue
        let wantsEmail = action == "email"

        // A raw number/email passes straight through; a name is looked up.
        let target: String
        if wantsEmail, contact.contains("@") {
            target = contact
        } else if !wantsEmail, Self.looksLikePhoneNumber(contact) {
            target = contact
        } else {
            // Only the matches that actually have the field we need (a phone for
            // call/text, an email for email).
            let matches = await resolver.resolve(name: contact)
                .filter { wantsEmail ? !$0.emails.isEmpty : !$0.phones.isEmpty }
            guard !matches.isEmpty else {
                let field = wantsEmail ? "email" : "phone number"
                return "Couldn't find a contact matching \"\(contact)\" with a \(field). "
                    + "The user may need to grant Contacts access in Settings → Privacy → Contacts."
            }
            // Disambiguate rather than risk reaching the wrong person.
            if matches.count > 1 {
                let names = matches.prefix(5).map(\.name).joined(separator: ", ")
                return "Multiple contacts match \"\(contact)\": \(names). Which one should I \(action)?"
            }
            target = (wantsEmail ? matches[0].emails.first : matches[0].phones.first)!
        }

        guard let url = Self.buildURL(action: action, target: target, message: message, subject: subject),
              let scheme = url.scheme else {
            throw ToolError.executionFailed("Could not build the \(action) URL")
        }
        guard appConfig.allows(scheme: scheme) else {
            return "The '\(scheme)' scheme isn't in the allowed list. Add it in Settings → Connectors."
        }
        await PrivacyLedger.shared.record(
            destination: .appLaunch(scheme: scheme, target: url.absoluteString),
            payload: url.absoluteString,
            redactions: 0
        )
        let ok = await opener.open(url)
        let verbs = ["call": "Calling", "text": "Texting", "email": "Emailing",
                     "facetime": "FaceTiming", "facetime_audio": "FaceTiming (audio)"]
        let verb = verbs[action] ?? "Contacting"
        return ok ? "\(verb) \(contact)." : "Couldn't \(action) \(contact)."
    }

    /// Heuristic: mostly digits, plausible length, only phone-ish characters.
    static func looksLikePhoneNumber(_ s: String) -> Bool {
        let digits = s.filter(\.isNumber)
        return digits.count >= 5 && !s.contains("@") &&
               s.allSatisfy { $0.isNumber || "+()-. ".contains($0) }
    }

    /// Builds the platform URL for an action. tel:/sms: use digits only; sms and
    /// mailto carry an optional body (and mailto an optional subject), percent-encoded.
    static func buildURL(action: String, target: String, message: String?, subject: String?) -> URL? {
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        }
        let digits = target.filter { $0.isNumber || $0 == "+" }
        // FaceTime accepts a phone number or an email; pass an email through as-is.
        let ftTarget = target.contains("@") ? target : digits
        switch action {
        case "call":
            return URL(string: "tel:\(digits)")
        case "facetime":
            return URL(string: "facetime:\(ftTarget)")
        case "facetime_audio":
            return URL(string: "facetime-audio:\(ftTarget)")
        case "text":
            var url = "sms:\(digits)"
            if let body = message, !body.isEmpty { url += "&body=\(enc(body))" }
            return URL(string: url)
        case "email":
            var query: [String] = []
            if let s = subject, !s.isEmpty { query.append("subject=\(enc(s))") }
            if let b = message, !b.isEmpty { query.append("body=\(enc(b))") }
            let suffix = query.isEmpty ? "" : "?" + query.joined(separator: "&")
            return URL(string: "mailto:\(target)\(suffix)")
        default:
            return nil
        }
    }
}

// MARK: - Broker policy

extension ContactActionTool {
    /// A call starts at once; a text or email opens its app ready to send.
    /// Either way someone else is on the other end.
    func risk(for arguments: JSONValue) -> RiskTier { .writeExternal }
    func describe(_ arguments: JSONValue) -> String {
        let who = ToolDescribing.text(arguments, "contact") ?? "someone"
        switch ToolDescribing.action(arguments) {
        case "call": return "Call \(who)"
        case "facetime": return "FaceTime \(who)"
        case "facetime_audio": return "FaceTime audio call \(who)"
        case "email":
            var text = "Email \(who)"
            if let subject = ToolDescribing.text(arguments, "subject") { text += ", subject " + ToolDescribing.quoted(subject) }
            if let message = ToolDescribing.text(arguments, "message") { text += ": " + ToolDescribing.quoted(message) }
            return text
        default:
            guard let message = ToolDescribing.text(arguments, "message") else { return "Text \(who)" }
            return "Text \(who): " + ToolDescribing.quoted(message)
        }
    }
    func approvalNote(for arguments: JSONValue) -> String? {
        switch ToolDescribing.action(arguments) {
        case "call", "facetime", "facetime_audio": return "This starts a call"
        case "email": return "This opens Mail with this email, ready to send"
        default: return "This opens Messages with this text, ready to send"
        }
    }
    var editableFields: [EditableField] {
        [EditableField(key: "message", label: "Message", kind: .text, optional: true),
         EditableField(key: "subject", label: "Subject", kind: .line, optional: true)]
    }
}
