import XCTest
@testable import Anu

@MainActor
final class SpotlightIndexerTests: XCTestCase {

    func testSearchableItemMapsWorkflowFields() {
        let workflow = Workflow(name: "Morning brief", prompt: "Summarize my unread mail and calendar")
        let item = SpotlightIndexer.searchableItem(for: workflow)

        XCTAssertEqual(item.uniqueIdentifier, workflow.id.uuidString)
        XCTAssertEqual(item.domainIdentifier, SpotlightIndexer.domainID)
        XCTAssertEqual(item.attributeSet.title, "Morning brief")
        // Privacy: the saved prompt must NOT leak into system-wide Spotlight —
        // only the workflow name is searchable.
        XCTAssertNotEqual(item.attributeSet.contentDescription, workflow.prompt)
        XCTAssertEqual(item.attributeSet.contentDescription, "Anu workflow")
    }

    func testReindexEmptyDoesNotCrash() {
        // Exercises the delete-then-(skip)index path with no items.
        SpotlightIndexer.shared.reindex([])
    }
}
