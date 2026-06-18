import XCTest
@testable import Anu

final class PrivateCloudModelTests: XCTestCase {

    override func tearDown() {
        KeychainStore.shared.remove(forKey: "pcs_endpoint")
        super.tearDown()
    }

    func testLoadThrowsWhenUnconfigured() async {
        KeychainStore.shared.remove(forKey: "pcs_endpoint")
        let model = PrivateCloudModel()
        do {
            try await model.load()
            XCTFail("expected load to fail when no endpoint is set")
        } catch let error as ModelError {
            if case .modelLoadFailed = error {} else { XCTFail("wrong ModelError: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testCatalogAvailabilityReflectsConfiguration() {
        let option = ModelCatalog.option(id: "privateCloud")!
        KeychainStore.shared.remove(forKey: "pcs_endpoint")
        if case .unsupported = ModelCatalog.availability(of: option) {
            // expected when unconfigured
        } else {
            XCTFail("private cloud should be unsupported when no endpoint is set")
        }
        KeychainStore.shared.set("https://pcs.test", forKey: "pcs_endpoint")
        XCTAssertEqual(ModelCatalog.availability(of: option), .ready)
    }

    func testEgressDestinationCountsAsLeavingDevice() {
        let dest = EgressDestination.privateComputeServer(endpoint: "pcs.test")
        XCTAssertTrue(dest.leavesDevice, "private server bytes still leave the device — must be counted")
        XCTAssertEqual(dest.displayName, "Private Compute")
        XCTAssertEqual(dest.iconName, "lock.shield")
        XCTAssertEqual(dest.detail, "pcs.test")
    }
}
