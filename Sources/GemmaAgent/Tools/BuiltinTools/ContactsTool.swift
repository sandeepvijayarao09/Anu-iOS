import Foundation
import Contacts

/// Read-only contact lookup by name via the Contacts framework. Requires
/// Contacts access (NSContactsUsageDescription). Denied access returns a
/// graceful message. Never modifies the address book.
struct ContactsTool: Tool {
    let name = "contacts"
    let description = "Look up a saved contact's phone number or email by name (read-only)."

    var parameters: JSONSchema? {
        .object(
            description: "Contact lookup parameters",
            properties: [
                "name": .string(description: "Full or partial name to search for"),
            ],
            required: ["name"]
        )
    }

    func execute(arguments: JSONValue) async throws -> String {
        guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
            throw ToolError.missingArgument("name")
        }

        let store = CNContactStore()
        let granted: Bool = await withCheckedContinuation { cont in
            store.requestAccess(for: .contacts) { ok, _ in cont.resume(returning: ok) }
        }
        guard granted else {
            return "Contacts access not granted. The user can enable it in Settings → Privacy → Contacts."
        }

        let keys = [
            CNContactGivenNameKey, CNContactFamilyNameKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
        ] as [CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matchingName: name)

        let matches: [CNContact]
        do { matches = try store.unifiedContacts(matching: predicate, keysToFetch: keys) }
        catch { return "Couldn't search contacts: \(error.localizedDescription)" }
        guard !matches.isEmpty else { return "No contact found matching \"\(name)\"." }

        let lines = matches.prefix(5).map { c -> String in
            let full = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            var line = full.isEmpty ? "(no name)" : full
            let phones = c.phoneNumbers.map { $0.value.stringValue }
            let emails = c.emailAddresses.map { String($0.value) }
            if !phones.isEmpty { line += " — phone: " + phones.joined(separator: ", ") }
            if !emails.isEmpty { line += " — email: " + emails.joined(separator: ", ") }
            return line
        }
        return "Found \(matches.count) contact(s):\n" + lines.joined(separator: "\n")
    }
}
