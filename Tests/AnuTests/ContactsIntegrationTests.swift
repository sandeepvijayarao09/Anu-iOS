import XCTest
import Contacts
@testable import Anu

/// REAL Contacts integration: seeds a contact in the simulator's address book,
/// then resolves it through the same `SystemContactResolver` that the
/// `contact_action` tool uses for "call/text/email <name>", and cleans up.
///
/// Permission-gated: skips if Contacts access isn't available, so the suite
/// stays stable. Grant before running with:
///   xcrun simctl privacy booted grant contacts io.github.sandeepvijayarao09.anu
final class ContactsIntegrationTests: XCTestCase {

    func testResolverFindsASeededContact() async throws {
        let store = CNContactStore()
        // Never ask: nobody answers a prompt under XCTest, and the wait hangs the run.
        let granted = CNContactStore.authorizationStatus(for: .contacts) == .authorized
        try XCTSkipUnless(granted, "Contacts access unavailable — skipping real Contacts integration test.")

        let given = "AnuIT\(Int.random(in: 1000...9999))"
        let seed = CNMutableContact()
        seed.givenName = given
        seed.familyName = "Tester"
        seed.phoneNumbers = [CNLabeledValue(
            label: CNLabelPhoneNumberMobile,
            value: CNPhoneNumber(stringValue: "+15550123456"))]
        let add = CNSaveRequest()
        add.add(seed, toContainerWithIdentifier: nil)
        do { try store.execute(add) } catch {
            throw XCTSkip("Couldn't seed a contact here: \(error.localizedDescription)")
        }
        defer { deleteContacts(named: given, in: store) }

        // Resolve through the REAL resolver the tool uses — proves name → phone
        // lookup works against the actual address book, not a mock.
        let matches = await SystemContactResolver().resolve(name: given)
        XCTAssertTrue(
            matches.contains { $0.name.contains(given) && !$0.phones.isEmpty },
            "resolver should find the seeded contact with a phone number — got \(matches)")
    }

    private func deleteContacts(named given: String, in store: CNContactStore) {
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey] as [CNKeyDescriptor]
        let pred = CNContact.predicateForContacts(matchingName: given)
        guard let found = try? store.unifiedContacts(matching: pred, keysToFetch: keys) else { return }
        let del = CNSaveRequest()
        for c in found {
            if let m = c.mutableCopy() as? CNMutableContact { del.delete(m) }
        }
        try? store.execute(del)
    }
}
