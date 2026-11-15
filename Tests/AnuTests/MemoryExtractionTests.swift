import XCTest
@testable import Anu

extension QueuedMockModel: OnDeviceLanguageModel {}

/// Memory v2, step 2: strict parsing with one repair (P6), the quote check,
/// secrets (I1), relation words, and dated facts (ADR-147).
final class MemoryExtractionTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: Parsing

    func testParsesStrictJSONAndFences() throws {
        let raw = """
        ```json
        {"facts":[{"subject":"user","predicate":"diet","value":"vegetarian","section":"preferences","quote":"I'm vegetarian","single":true}]}
        ```
        """
        let facts = try XCTUnwrap(FactExtractor.parse(raw))
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts[0].section, .preferences)
        XCTAssertTrue(facts[0].single)
        XCTAssertEqual(FactExtractor.parse(#"{"facts":[]}"#), [])
    }

    func testRejectsAnythingThatIsntExactlyTheFormat() {
        XCTAssertNil(FactExtractor.parse("Sure! Here are the facts: {\"facts\":[]}"), "prose around the JSON fails")
        XCTAssertNil(FactExtractor.parse(#"{"facts":[]} thanks"#))
        XCTAssertNil(FactExtractor.parse(#"{"items":[]}"#), "no facts array")
        XCTAssertNil(FactExtractor.parse(#"{"facts":[{"subject":"user","predicate":"diet","value":"vegan"}]}"#), "missing quote")
        XCTAssertNil(FactExtractor.parse(#"{"facts":[{"subject":"user","predicate":"diet","value":3,"quote":"x","section":"identity"}]}"#))
        XCTAssertNil(FactExtractor.parse(#"{"facts":[{"subject":"user","predicate":"diet","value":"v","quote":"v","sensitive":"yes"}]}"#))
    }

    func testMadeUpSectionIsFiledByCode() throws {
        let raw = #"{"facts":[{"subject":"me","predicate":"allergy","value":"peanuts","section":"health","quote":"allergic to peanuts"},{"subject":"Maya","predicate":"birthday","value":"12 March","section":"birthdays","quote":"Maya's birthday is 12 March"}]}"#
        let facts = try XCTUnwrap(FactExtractor.parse(raw))
        XCTAssertEqual(facts.map(\.section), [.identity, .people])
    }

    // MARK: Accepting a fact

    func testKeepsOnlyFactsTheMessageSays() {
        let message = "My manager Maya wants the report by Friday."
        let said = ExtractedFact(subject: "I", predicate: "Boss", value: "Maya", section: .people, quote: "My manager Maya")
        let kept = FactExtractor.accept(said, message: message)
        XCTAssertEqual(kept?.subject, MemoryFact.user)
        XCTAssertEqual(kept?.predicate, "manager", "boss is filed under its canonical relation")
        let invented = ExtractedFact(subject: "user", predicate: "lives_in", value: "Paris", section: .places, quote: "I live in Paris")
        XCTAssertNil(FactExtractor.accept(invented, message: message), "neither quote nor value is in the message")
    }

    func testNeverKeepsSecretsOrVagueChangeDays() {
        let msg = "my wifi password is hunter22 and I'm moving next month, my card 4111 1111 1111 1111"
        XCTAssertNil(FactExtractor.accept(ExtractedFact(subject: "user", predicate: "wifi_password", value: "hunter22", section: .identity, quote: "my wifi password is hunter22"), message: msg))
        XCTAssertNil(FactExtractor.accept(ExtractedFact(subject: "user", predicate: "card", value: "4111 1111 1111 1111", section: .identity, quote: "my card 4111 1111 1111 1111"), message: msg))
        XCTAssertNil(FactExtractor.accept(ExtractedFact(subject: "user", predicate: "move_date", value: "next month", section: .places, quote: "moving next month"), message: msg))
    }

    func testCaptureFilters() {
        XCTAssertNil(MemoryFilters.forChat("Book lunch with Maya tomorrow"), "requests about no one aren't captured")
        XCTAssertNil(MemoryFilters.forChat("my verification code is 123456"))
        XCTAssertNil(MemoryFilters.forChat("ok"))
        XCTAssertEqual(MemoryFilters.forChat("I'm vegetarian these days"), "I'm vegetarian these days")
        XCTAssertEqual(MemoryFilters.cleaned("my SSN is 123-45-6789 and I'm Sam"), "my SSN is [ID] and I'm Sam")
    }

    func testFingerprintIgnoresSpellingOfTheSameFact() {
        XCTAssertEqual(MemoryNormalize.fingerprint(subject: "me", predicate: "Home City", value: "Pune!"),
                       MemoryNormalize.fingerprint(subject: "user", predicate: "lives_in", value: "pune"))
    }

    // MARK: Dated facts (ADR-147)

    func testDayComesFromTheWordsFirst() {
        let today = day(2026, 11, 12)   // a Thursday
        XCTAssertEqual(UpcomingDay.start(starts: "2026-11-20", quote: "I'm moving to Denver next month", today: today, calendar: calendar), day(2026, 12, 1))
        XCTAssertEqual(UpcomingDay.start(starts: nil, quote: "starting at Acme in 3 weeks", today: today, calendar: calendar), day(2026, 12, 3))
        XCTAssertEqual(UpcomingDay.start(starts: nil, quote: "I start at Acme in March", today: today, calendar: calendar), day(2027, 3, 1))
        XCTAssertEqual(UpcomingDay.start(starts: nil, quote: "moving on Friday", today: today, calendar: calendar), day(2026, 11, 13))
        XCTAssertEqual(UpcomingDay.start(starts: nil, quote: "I'm starting tomorrow at Acme", today: today, calendar: calendar), day(2026, 11, 13))
    }

    func testDayFromTheModelThenUndatedFuture() {
        let today = day(2026, 11, 12)
        XCTAssertEqual(UpcomingDay.start(starts: "2027-01-15", quote: "I will start at Globex", today: today, calendar: calendar), day(2027, 1, 15))
        XCTAssertEqual(UpcomingDay.start(starts: nil, quote: "I'm moving to Lisbon", today: today, calendar: calendar), day(2026, 12, 12), "30 days on")
    }

    func testOnlyAChangeHasAStartDay() {
        let today = day(2026, 11, 12)
        XCTAssertNil(UpcomingDay.start(starts: nil, quote: "Maya's birthday is in June", today: today, calendar: calendar))
        XCTAssertNil(UpcomingDay.start(starts: nil, quote: "I moved to Pune last month", today: today, calendar: calendar))
        XCTAssertNil(UpcomingDay.start(starts: "2026-01-01", quote: "I'm starting yoga", today: today, calendar: calendar), "a past day means true now")
    }

    func testShortQuoteReadsItsSentence() {
        let today = day(2026, 11, 12)
        XCTAssertEqual(UpcomingDay.start(starts: "2026-12-12", quote: "moving to Tallinn", today: today,
                                         message: "Big news. I'm moving to Tallinn next month!", calendar: calendar),
                       day(2026, 12, 1))
    }

    // MARK: The extractor and its one repair (P6)

    func testRepairsOnceThenSucceeds() async {
        let model = QueuedMockModel([
            "Here you go: facts are diet vegetarian",
            #"{"facts":[{"subject":"user","predicate":"diet","value":"vegetarian","section":"preferences","quote":"I'm vegetarian"}]}"#,
        ])
        let result = await FactExtractor(model: model, calendar: calendar).extract("By the way, I'm vegetarian.")
        XCTAssertEqual(result, .facts([ExtractedFact(subject: "user", predicate: "diet", value: "vegetarian", section: .preferences, quote: "I'm vegetarian")]))
        XCTAssertEqual(model.capturedPrompts.count, 2)
        XCTAssertTrue(model.capturedPrompts[1].contains("That wasn't valid JSON"), "the repair shows the expected shape")
        XCTAssertTrue(model.capturedPrompts[1].contains("Here you go"), "and the model's own answer")
    }

    func testGivesUpAfterOneRepair() async {
        let model = QueuedMockModel(["nope", "still nope", "never asked"])
        let result = await FactExtractor(model: model, calendar: calendar).extract("I'm vegan")
        guard case .failed = result else { return XCTFail("expected failure, got \(result)") }
        XCTAssertEqual(model.capturedPrompts.count, 2, "exactly one repair")
    }

    func testGenerationErrorIsNotTheMessagesFault() async {
        let model = QueuedMockModel(["\n[Generation error: GPU unavailable]"])
        let result = await FactExtractor(model: model, calendar: calendar).extract("I'm vegan")
        guard case .unavailable = result else { return XCTFail("expected unavailable, got \(result)") }
    }

    func testPromptCarriesTodayAndNoTools() async {
        let model = QueuedMockModel([#"{"facts":[]}"#])
        _ = await FactExtractor(model: model, today: day(2026, 11, 12), calendar: calendar).extract("I'm vegan")
        let prompt = model.capturedPrompts[0]
        XCTAssertTrue(prompt.contains("Today is Thursday, 12 November 2026."))
        XCTAssertFalse(prompt.contains("Available tools"))
        XCTAssertTrue(prompt.contains(FactExtractor.messageHeader + "I'm vegan"))
    }

    func testScriptedModelExtractsEndToEnd() async {
        let result = await FactExtractor(model: ScriptedModel(), calendar: calendar)
            .extract("My manager is Maya Chen and I'm vegetarian")
        guard case .facts(let facts) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(Set(facts.map(\.predicate)), ["diet", "manager"])
        XCTAssertEqual(facts.first { $0.predicate == "manager" }?.value, "Maya Chen")
    }
}
