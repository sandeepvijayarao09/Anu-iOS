import XCTest
@testable import GemmaAgent

final class UnitConverterToolTests: XCTestCase {

    private func convert(_ value: Double, _ from: String, _ to: String) async throws -> String {
        try await UnitConverterTool().execute(arguments: .object([
            "value": .double(value), "from": .string(from), "to": .string(to),
        ]))
    }

    func testMilesToKilometers() async throws {
        let out = try await convert(5, "miles", "km")
        XCTAssertTrue(out.contains("8.04672"), out)
    }

    func testCelsiusToFahrenheit() async throws {
        let out = try await convert(100, "celsius", "fahrenheit")
        XCTAssertTrue(out.contains("212"), out)
    }

    func testKilogramsToPounds() async throws {
        let out = try await convert(10, "kg", "lb")
        XCTAssertTrue(out.contains("22.04"), out)
    }

    func testHoursToMinutes() async throws {
        let out = try await convert(2, "hours", "minutes")
        XCTAssertTrue(out.contains("120"), out)
    }

    func testMismatchedCategoriesThrows() async {
        do {
            _ = try await convert(5, "miles", "kg")
            XCTFail("expected a category-mismatch error")
        } catch { /* expected */ }
    }

    func testUnknownUnitThrows() async {
        do {
            _ = try await convert(5, "smoots", "km")
            XCTFail("expected an unknown-unit error")
        } catch { /* expected */ }
    }

    func testMissingValueThrows() async {
        do {
            _ = try await UnitConverterTool().execute(arguments: .object([
                "from": .string("m"), "to": .string("km"),
            ]))
            XCTFail("expected a missing-argument error")
        } catch { /* expected */ }
    }
}
