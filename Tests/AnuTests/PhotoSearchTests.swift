import XCTest
@testable import Anu

/// Photo search by contents (AI Edge Gallery's Media Search), on the device.
final class PhotoSearchTests: XCTestCase {
    func testWordsBecomeLabelsWithSynonyms() {
        XCTAssertEqual(PhotoSearch.wanted("my photos of waterfalls"), [["waterfall"]])
        XCTAssertEqual(PhotoSearch.wanted("puppies"), [["puppy"]].map { _ in ["dog", "puppy"] })
        XCTAssertEqual(PhotoSearch.wanted("the beach"), [["beach", "shore", "sand", "coast"]])
        XCTAssertTrue(PhotoSearch.wanted("photos").isEmpty, "no subject, no search")
    }

    func testSingulars() {
        XCTAssertEqual(PhotoSearch.singular("flowers"), "flower")
        XCTAssertEqual(PhotoSearch.singular("puppies"), "puppy")
        XCTAssertEqual(PhotoSearch.singular("beaches"), "beach")
        XCTAssertEqual(PhotoSearch.singular("grass"), "grass")
    }

    func testMatchingNeedsEveryWordAtAConfidence() {
        let labels: [String: Float] = ["flower": 0.9, "plant": 0.8, "sky": 0.1, "dog": 0.4]
        XCTAssertTrue(PhotoSearch.matches(PhotoSearch.wanted("flowers"), labels: labels))
        XCTAssertTrue(PhotoSearch.matches(PhotoSearch.wanted("dog with flowers"), labels: labels))
        XCTAssertFalse(PhotoSearch.matches(PhotoSearch.wanted("sky"), labels: labels), "0.1 is too unsure")
        XCTAssertFalse(PhotoSearch.matches(PhotoSearch.wanted("cats"), labels: labels))
        XCTAssertTrue(PhotoSearch.matches(PhotoSearch.wanted("waterfall"), labels: ["waterfall": 0.6]))
    }

    func testSpokenRequestsGoToTheSearch() {
        let search = { (q: String) in DirectCommand.tool(name: "photos", arguments: .object(["action": .string("search"), "query": .string(q)])) }
        XCTAssertEqual(PhoneCommands.match("Find my photos of waterfalls"), search("waterfalls"))
        XCTAssertEqual(PhoneCommands.match("show me pictures with dogs"), search("dogs"))
        XCTAssertNil(PhoneCommands.match("find my photos"), "nothing to look for")
        XCTAssertNil(PhoneCommands.match("how many photos do I have"))
    }

    func testShownPicturesAreTakenOnce() {
        PhotoSearch.keepShown([Data([1]), Data([2])])
        XCTAssertEqual(PhotoSearch.takeShown().count, 2)
        XCTAssertTrue(PhotoSearch.takeShown().isEmpty)
    }
}

