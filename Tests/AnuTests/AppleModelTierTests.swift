import XCTest
@testable import Anu

/// A stand-in for Apple's models' availability, so tier choices are tested
/// on any simulator without Apple Intelligence.
struct FakeAppleAvailability: AppleModelAvailabilityChecking {
    var onDevice: AppleModelStatus = .unavailable(.deviceNotEligible)
    var privateCloud: AppleModelStatus = .unavailable(.notEntitled)

    func status(of kind: AppleModelKind) -> AppleModelStatus {
        kind == .onDevice ? onDevice : privateCloud
    }
}

/// Answers PCC prompts from a script, or fails the way PCC does.
struct FakePrivateCloud: PrivateCloudGenerating {
    var answer: String = "PCC answer"
    var failure: PrivateCloudFailure?
    func generate(prompt: String) async throws -> String {
        if let failure { throw failure }
        return answer
    }
}

/// Parity A1: Apple's on-device model as the Base tier, PCC as the private
/// cloud tier, Gemma and then Gemini behind them, with honest reasons.
@MainActor
final class AppleModelTierTests: XCTestCase {
    /// Whether this build has Apple's tiers (Xcode 27's SDK) and this OS can run them.
    static var appleTierBuilt: Bool {
        #if compiler(>=6.4)  // iOS 27 SDK APIs (Xcode 27)
        if #available(iOS 27.0, macOS 27.0, *) { return true }
        #endif
        return false
    }

    private var savedAvailability: (any AppleModelAvailabilityChecking)!
    private var savedSelection: String?

    override func setUp() {
        super.setUp()
        savedAvailability = AppleModels.availability
        savedSelection = UserDefaults.standard.string(forKey: ModelManager.selectionKey)
    }

    override func tearDown() {
        AppleModels.availability = savedAvailability
        if let savedSelection { UserDefaults.standard.set(savedSelection, forKey: ModelManager.selectionKey) }
        else { UserDefaults.standard.removeObject(forKey: ModelManager.selectionKey) }
        super.tearDown()
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "apple-tier-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: Base-tier choice

    func testAutomaticPrefersAppleWhenAvailable() {
        XCTAssertEqual(BaseTierResolver.resolve(selection: .automatic, apple: .available, gemmaReady: true), .apple)
    }

    func testAutomaticFallsBackToGemmaWhenAppleIsOff() {
        XCTAssertEqual(BaseTierResolver.resolve(selection: .automatic,
                                                apple: .unavailable(.appleIntelligenceNotEnabled), gemmaReady: true), .gemma)
    }

    func testAutomaticWithNothingSaysWhy() {
        XCTAssertEqual(BaseTierResolver.resolve(selection: .automatic, apple: .unavailable(.osTooOld), gemmaReady: false),
                       .unavailable(UnavailableModel.defaultReason))
    }

    func testAppleSelectionNeverSilentlySwapsToGemma() {
        let engine = BaseTierResolver.resolve(selection: .appleOnDevice, apple: .unavailable(.modelNotReady), gemmaReady: true)
        guard case .unavailable(let why) = engine else { return XCTFail("\(engine)") }
        XCTAssertTrue(why.contains("still downloading"), why)
    }

    func testGemmaSelectionIgnoresApple() {
        XCTAssertEqual(BaseTierResolver.resolve(selection: .liteRT, apple: .available, gemmaReady: true), .gemma)
        XCTAssertEqual(BaseTierResolver.resolve(selection: .downloadable, apple: .available, gemmaReady: true), .gemma)
    }

    func testEveryReasonHasPlainWords() {
        let reasons: [AppleModelUnavailableReason] = [
            .osTooOld, .frameworkMissing, .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady,
            .systemNotReady, .notEntitled, .quotaExhausted(resetDate: nil), .temporarilyUnreachable,
        ]
        for reason in reasons { XCTAssertFalse(reason.userText.isEmpty, "\(reason)") }
        XCTAssertTrue(AppleModelUnavailableReason.quotaExhausted(resetDate: Date()).userText.contains("resets"))
        XCTAssertTrue(AppleModelUnavailableReason.appleIntelligenceNotEnabled.userText.contains("Settings"))
    }

    // MARK: Model picker and factory

    func testCatalogOffersAppleGemmaAndAutomatic() {
        let ids = ModelCatalog.all.map(\.id)
        XCTAssertEqual(Array(ids.prefix(3)), ["automatic", "apple", "liteRT"])
        XCTAssertEqual(ModelCatalog.kind(forID: "apple"), .appleOnDevice)
        XCTAssertEqual(ModelCatalog.appleOption.displayName, "Apple on-device")
    }

    func testAppleRowShowsTheReasonWhenUnavailable() {
        AppleModels.availability = FakeAppleAvailability(onDevice: .unavailable(.deviceNotEligible))
        XCTAssertEqual(ModelCatalog.availability(of: ModelCatalog.appleOption),
                       .unsupported(AppleModelUnavailableReason.deviceNotEligible.userText))
        AppleModels.availability = FakeAppleAvailability(onDevice: .available)
        XCTAssertEqual(ModelCatalog.availability(of: ModelCatalog.appleOption), .ready)
    }

    func testChoosingAppleWhenUnavailableFailsLoudlyWithTheReason() async {
        AppleModels.availability = FakeAppleAvailability(onDevice: .unavailable(.appleIntelligenceNotEnabled))
        UserDefaults.standard.set("apple", forKey: ModelManager.selectionKey)
        let model = ModelFactory.makeModel()
        XCTAssertTrue(model is UnavailableModel)
        do {
            try await model.load()
            XCTFail("expected a load failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Apple Intelligence is off"), error.localizedDescription)
        }
    }

    func testAutomaticPicksAppleOnAnEligibleDevice() throws {
        #if targetEnvironment(simulator)
        // The Simulator says Apple's model is available but has no files for
        // it, so Automatic deliberately uses a bundled Gemma there.
        try XCTSkipIf(Bundle.main.path(forResource: "gemma4e4b", ofType: "litertlm") != nil,
                      "the Simulator prefers the bundled Gemma")
        #endif
        AppleModels.availability = FakeAppleAvailability(onDevice: .available)
        UserDefaults.standard.set("automatic", forKey: ModelManager.selectionKey)
        let model = ModelFactory.makeModel()
        if Self.appleTierBuilt {
            XCTAssertEqual(model.modelName, "Apple on-device")
            XCTAssertTrue(model is any NativeToolCallingModel)
        } else {
            XCTAssertNotEqual(model.modelName, "Apple on-device")
        }
    }

    func testAutomaticSkipsAppleWhenNotReady() {
        AppleModels.availability = FakeAppleAvailability(onDevice: .unavailable(.modelNotReady))
        UserDefaults.standard.set("automatic", forKey: ModelManager.selectionKey)
        XCTAssertNotEqual(ModelFactory.makeModel().modelName, "Apple on-device")
    }

    // MARK: Private Cloud Compute

    func testPrivateCloudNeedsTheEntitlement() {
        let checker = SystemAppleModelAvailability(entitlementGranted: { false },
                                                   backoff: PrivateCloudBackoff(defaults: isolatedDefaults()))
        let status = checker.status(of: .privateCloud)
        #if canImport(FoundationModels) && compiler(>=6.4)  // iOS 27 SDK APIs (Xcode 27)
        // Built with Apple's tiers: an older OS can't run them.
        XCTAssertEqual(status, .unavailable(Self.appleTierBuilt ? .notEntitled : .osTooOld))
        #else
        // Built with Xcode 26 (CI today): the tiers aren't in the app at all.
        XCTAssertEqual(status, .unavailable(.frameworkMissing))
        #endif
        XCTAssertFalse(PrivateCloudEntitlement.isGranted(), "the shipping Info.plist doesn't claim the entitlement")
    }

    func testBackoffSkipsUntilTheQuotaResets() {
        let backoff = PrivateCloudBackoff(defaults: isolatedDefaults())
        let now = Date()
        let reset = now.addingTimeInterval(3600)
        XCTAssertNil(backoff.reason(now: now))
        backoff.quotaReached(resetDate: reset, now: now)
        XCTAssertEqual(backoff.reason(now: now), .quotaExhausted(resetDate: reset))
        XCTAssertNil(backoff.reason(now: reset.addingTimeInterval(1)))
    }

    func testBackoffAfterANetworkFailureIsShort() {
        let backoff = PrivateCloudBackoff(defaults: isolatedDefaults())
        let now = Date()
        backoff.unreachable(now: now)
        XCTAssertEqual(backoff.reason(now: now.addingTimeInterval(60)), .temporarilyUnreachable)
        XCTAssertNil(backoff.reason(now: now.addingTimeInterval(PrivateCloudBackoff.unreachableWait + 1)))
        backoff.reset()
        XCTAssertNil(backoff.reason(now: now))
    }

    func testPCCToolAnswersAndRecordsRedactedEgress() async throws {
        PrivacyLedger.shared.beginTurn()
        let tool = EscalateToApplePCCTool(generator: FakePrivateCloud(answer: "Here's the essay."),
                                          availability: { .available },
                                          backoff: PrivateCloudBackoff(defaults: isolatedDefaults()))
        let result = try await tool.execute(arguments: .object(["task": .string("Write to maya@example.com about solar")]))
        XCTAssertEqual(result, EscalateToApplePCCTool.responsePrefix + "Here's the essay.")
        XCTAssertEqual(CloudProvider.applePCC.stripResponsePrefix(result), "Here's the essay.")
        let event = try XCTUnwrap(PrivacyLedger.shared.events.last)
        XCTAssertEqual(event.destination, .applePrivateCloud)
        XCTAssertTrue(event.destination.leavesDevice)
        XCTAssertEqual(event.redactions, 1)
        XCTAssertFalse(event.payloadSummary.contains("maya@example.com"))
    }

    func testPCCToolOutOfQuotaBacksOffAndSaysSo() async throws {
        let backoff = PrivateCloudBackoff(defaults: isolatedDefaults())
        let reset = Date().addingTimeInterval(7200)
        let tool = EscalateToApplePCCTool(
            generator: FakePrivateCloud(failure: .unavailable(.quotaExhausted(resetDate: reset))),
            availability: { .available }, backoff: backoff)
        let result = try await tool.execute(arguments: .object(["task": .string("hard thing")]))
        XCTAssertTrue(EscalateToApplePCCTool.isUnavailableResult(result), result)
        XCTAssertEqual(backoff.reason(), .quotaExhausted(resetDate: reset))
    }

    func testPCCToolSendsNothingWhenUnavailable() async throws {
        let before = PrivacyLedger.shared.events.count
        let tool = EscalateToApplePCCTool(generator: FakePrivateCloud(), availability: { .unavailable(.notEntitled) },
                                          backoff: PrivateCloudBackoff(defaults: isolatedDefaults()))
        let result = try await tool.execute(arguments: .object(["task": .string("hard thing")]))
        XCTAssertEqual(result, EscalateToApplePCCTool.unavailable(.notEntitled))
        XCTAssertEqual(PrivacyLedger.shared.events.count, before, "nothing left the device")
    }

    func testPCCIsTheCloudTierBeforeGeminiOnlyWhenUsable() throws {
        try requireWorkingKeychain()
        KeychainStore.shared.remove(forKey: "pcs_endpoint")
        UserDefaults.standard.removeObject(forKey: CloudProvider.preferenceKey)
        defer { Vault.shared.delete(.gemini) }
        try? KnownSecret.gemini.store("AIzaKEY")

        AppleModels.availability = FakeAppleAvailability(privateCloud: .available)
        XCTAssertEqual(CloudProvider.resolved(), .applePCC)
        XCTAssertEqual(CloudProvider.applePCC.escalationToolName, "escalate_to_apple_pcc")

        AppleModels.availability = FakeAppleAvailability(privateCloud: .unavailable(.quotaExhausted(resetDate: nil)))
        XCTAssertEqual(CloudProvider.resolved(), .gemini, "out of quota → Gemini")
    }

    func testAboutThisAnswerNamesApplePCC() {
        let details = AnswerDetails(tier: .applePrivateCloud, modelName: "Apple Private Cloud Compute")
        XCTAssertEqual(AnswerDetailsText.caption(details), "Apple Private Cloud Compute")
        XCTAssertTrue(AnswerDetailsText.whereItWent(details).contains("Apple"))
    }
}
