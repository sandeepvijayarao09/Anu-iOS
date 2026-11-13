import XCTest
@testable import Anu

/// Delete All My Data (App Review 5.1.1) and the App Store compliance keys
/// the built app must carry (privacy manifest, usage strings, encryption).
final class DataEraserTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataEraserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func dir(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func eraser(_ locations: [DataEraser.Location], defaults: UserDefaults = .standard,
                        domain: String? = nil) -> DataEraser {
        DataEraser(locations: locations, defaultsDomain: domain, defaults: defaults,
                   keychainServices: [], markerURL: root.appendingPathComponent("Library/.anu-erase-pending"))
    }

    func testEmptiesEachLocationButKeepsTheModel() throws {
        let docs = try dir("Documents"), support = try dir("Support")
        touch(docs.appendingPathComponent("memory.json"))
        touch(docs.appendingPathComponent("sessions/index.json"))
        touch(support.appendingPathComponent("Skills/a/SKILL.md"))
        touch(support.appendingPathComponent("Models/gemma.litertlm"))

        let removed = eraser([.init(directory: docs), .init(directory: support, keep: DataEraser.modelFolders)])
            .eraseStoredData()

        XCTAssertEqual(removed, 3)
        XCTAssertFalse(exists(docs.appendingPathComponent("memory.json")))
        XCTAssertFalse(exists(docs.appendingPathComponent("sessions")))
        XCTAssertFalse(exists(support.appendingPathComponent("Skills")))
        XCTAssertTrue(exists(support.appendingPathComponent("Models/gemma.litertlm")))
    }

    /// The Mac app isn't sandboxed: its Documents is the user's own, so only
    /// Anu's files go.
    func testOnlyListRemovesAnuFilesAndNothingElse() throws {
        let docs = try dir("Documents")
        touch(docs.appendingPathComponent("memory.json"))
        touch(docs.appendingPathComponent("privacy_ledger.json"))
        touch(docs.appendingPathComponent("Tax return 2025.pdf"))

        eraser([.init(directory: docs, only: DataEraser.knownDocuments)]).eraseStoredData()

        XCTAssertFalse(exists(docs.appendingPathComponent("memory.json")))
        XCTAssertFalse(exists(docs.appendingPathComponent("privacy_ledger.json")))
        XCTAssertTrue(exists(docs.appendingPathComponent("Tax return 2025.pdf")))
    }

    func testRemovesTheSettingsDomain() throws {
        let domain = "DataEraserTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(true, forKey: "fast_mode")
        defaults.set("abc", forKey: "mac_pairing")

        eraser([], defaults: defaults, domain: domain).eraseStoredData()

        XCTAssertNil(defaults.persistentDomain(forName: domain)?["fast_mode"])
        XCTAssertNil(defaults.persistentDomain(forName: domain)?["mac_pairing"])
    }

    func testPendingEraseRunsOnceAtNextLaunch() throws {
        let docs = try dir("Documents")
        let e = eraser([.init(directory: docs)])
        XCTAssertFalse(e.isPending)
        DataEraser.finishPendingErase(e) // nothing pending: nothing happens
        touch(docs.appendingPathComponent("conversation.json"))
        XCTAssertTrue(exists(docs.appendingPathComponent("conversation.json")))

        e.markPending()
        XCTAssertTrue(e.isPending)
        // A stale copy written back after the erase, before the app closed.
        DataEraser.finishPendingErase(e)

        XCTAssertFalse(exists(docs.appendingPathComponent("conversation.json")))
        XCTAssertFalse(e.isPending)
    }

    func testTheMarkerSurvivesAnEraseOfItsOwnFolder() throws {
        let library = try dir("Library")
        let e = eraser([.init(directory: library)])
        e.markPending()
        touch(library.appendingPathComponent("stale.json"))
        e.eraseStoredData()
        XCTAssertTrue(e.isPending)
        XCTAssertFalse(exists(library.appendingPathComponent("stale.json")))
    }

    func testLiveErasesOnlyAnuKeychainServices() {
        XCTAssertEqual(Set(DataEraser.live.keychainServices),
                       ["com.anu.app", "com.gemmaagent.app", "com.anu.app.vault", "com.anu.app.shared"])
    }

    // MARK: - What the built app declares

    private func manifest() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
                                "the app bundle carries PrivacyInfo.xcprivacy")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testPrivacyManifestDeclaresNoTrackingAndEveryRequiredReasonCategory() throws {
        let m = try manifest()
        XCTAssertEqual(m["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((m["NSPrivacyTrackingDomains"] as? [String])?.isEmpty, true)
        let apis = try XCTUnwrap(m["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: Set<String>] = [:]
        for api in apis {
            let type = try XCTUnwrap(api["NSPrivacyAccessedAPIType"] as? String)
            reasons[type] = Set(api["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [])
        }
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryFileTimestamp"], ["C617.1", "3B52.1"])
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategorySystemBootTime"], ["35F9.1"])
        XCTAssertNil(reasons["NSPrivacyAccessedAPICategoryDiskSpace"], "no disk-space API is used")
        XCTAssertNil(reasons["NSPrivacyAccessedAPICategoryActiveKeyboards"], "activeInputModes is not used")
    }

    func testPrivacyManifestDeclaresWhatTheCloudHelperAndSearchReceive() throws {
        let collected = try XCTUnwrap(manifest()["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let types = Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        XCTAssertEqual(types, ["NSPrivacyCollectedDataTypeOtherUserContent", "NSPrivacyCollectedDataTypeSearchHistory"])
        for entry in collected {
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, false)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypePurposes"] as? [String],
                           ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
        }
    }

    func testInfoPlistCarriesComplianceKeys() {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(info["ITSAppUsesNonExemptEncryption"] as? Bool, false)
        for key in ["NSFaceIDUsageDescription", "NSCameraUsageDescription", "NSMicrophoneUsageDescription",
                    "NSSpeechRecognitionUsageDescription", "NSPhotoLibraryUsageDescription",
                    "NSPhotoLibraryAddUsageDescription", "NSContactsUsageDescription",
                    "NSCalendarsFullAccessUsageDescription", "NSRemindersFullAccessUsageDescription",
                    "NSLocalNetworkUsageDescription", "NSAlarmKitUsageDescription"] {
            let value = info[key] as? String ?? ""
            XCTAssertGreaterThan(value.count, 20, "\(key) is present and specific")
        }
        XCTAssertNil(info["NSUserTrackingUsageDescription"], "Anu doesn't track, so it never asks to")
        XCTAssertNil(info["NSLocationWhenInUseUsageDescription"], "no location access")
        XCTAssertNil(info["NSBluetoothAlwaysUsageDescription"], "no Bluetooth access")
    }
}
