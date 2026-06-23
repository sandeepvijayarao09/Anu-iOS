import XCTest
@testable import Anu

final class CalculatorToolTests: XCTestCase {
    let tool = CalculatorTool()

    private func run(_ expression: String) async throws -> String {
        try await tool.execute(arguments: .object(["expression": .string(expression)]))
    }

    func testBasicArithmetic() async throws {
        let result = try await run("12 * 8 + 5")
        XCTAssertTrue(result.contains("101"), result)
    }

    func testOperatorPrecedence() async throws {
        let result = try await run("2 + 3 * 4")
        XCTAssertTrue(result.contains("14"), result)
    }

    func testParentheses() async throws {
        let result = try await run("(2 + 3) * 4")
        XCTAssertTrue(result.contains("20"), result)
    }

    func testPower() async throws {
        let result = try await run("2 ^ 10")
        XCTAssertTrue(result.contains("1024"), result)
    }

    func testFunctions() async throws {
        let sqrtResult = try await run("sqrt(144)")
        XCTAssertTrue(sqrtResult.contains("12"), sqrtResult)

        let maxResult = try await run("max(3, 7)")
        XCTAssertTrue(maxResult.contains("7"), maxResult)
    }

    func testConstants() async throws {
        let result = try await run("pi")
        XCTAssertTrue(result.contains("3.14"), result)
    }

    func testNegativeNumbers() async throws {
        let result = try await run("-5 + 3")
        XCTAssertTrue(result.contains("-2"), result)
    }

    func testDivisionByZeroThrows() async {
        do {
            _ = try await run("1 / 0")
            XCTFail("expected division by zero to throw")
        } catch {
            // expected
        }
    }

    func testMissingArgumentThrows() async {
        do {
            _ = try await tool.execute(arguments: .object([:]))
            XCTFail("expected missing argument to throw")
        } catch {
            // expected
        }
    }

    // MARK: - Crash regressions (these used to trap, not throw)

    func testNaNDoesNotCrash() async {
        // sqrt(-1) = NaN — must throw, never Int(NaN) trap
        do { _ = try await run("sqrt(-1)"); XCTFail("expected throw") }
        catch { /* ok */ }
    }

    func testInfinityDoesNotCrash() async {
        do { _ = try await run("log(0)"); XCTFail("expected throw") }
        catch { /* ok */ }
    }

    func testIntOverflowDoesNotCrash() async throws {
        // 9^99 overflows Int — must format as a double string, not trap
        let result = try await run("9^99")
        XCTAssertFalse(result.isEmpty)
    }

    func testMissingFunctionArgDoesNotCrash() async {
        // sqrt() with no args used to trap on args[0]
        do { _ = try await run("sqrt()"); XCTFail("expected throw") }
        catch { /* ok */ }
    }

    func testOneArgToBinaryFunctionDoesNotCrash() async {
        do { _ = try await run("atan2(1)"); XCTFail("expected throw") }
        catch { /* ok */ }
    }

    func testUnaryMinusPrecedence() async throws {
        // -2^2 should be -(2^2) = -4 by math convention
        let result = try await run("-2^2")
        XCTAssertTrue(result.contains("-4"), result)
    }

    func testTrailingTokensThrow() async {
        // "2 3" used to silently return 2; stray tokens must error, not return
        // a confidently-wrong partial result.
        do { _ = try await run("2 3"); XCTFail("expected throw on trailing tokens") }
        catch { /* ok */ }
    }

}
