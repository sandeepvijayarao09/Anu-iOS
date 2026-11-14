import XCTest
import CryptoKit
@testable import Anu

/// `run_js`'s JavaScriptCore sandbox: what goes in, what comes out, and the
/// limits (ADR-120).
final class JSSandboxTests: XCTestCase {
    private let sandbox = JSSandbox()

    func testStringInStringOut() async throws {
        let out = try await sandbox.run(script: "function run(d) { return d.toUpperCase() }", data: "abc")
        XCTAssertEqual(out, "ABC")
    }

    func testGalleryEntryPointWinsAndObjectsComeBackAsJSON() async throws {
        let script = """
        function run(d) { return "wrong" }
        function ai_edge_gallery_get_result(d) { const p = JSON.parse(d); return { result: p.n * 2 } }
        """
        let out = try await sandbox.run(script: script, data: #"{"n": 21}"#)
        XCTAssertEqual(out, #"{"result":42}"#)
    }

    func testDataIsPassedAsAStringNeverAsCode() async throws {
        let hostile = #""); throw new Error("escaped"); (""#
        let out = try await sandbox.run(script: "function run(d) { return d }", data: hostile)
        XCTAssertEqual(out, hostile)
    }

    func testPromisesAreAwaited() async throws {
        let out = try await sandbox.run(
            script: "async function run(d) { const x = await Promise.resolve(d + '!'); return x }", data: "hi")
        XCTAssertEqual(out, "hi!")
        do {
            _ = try await sandbox.run(script: "async function run(d) { throw new Error('nope') }", data: "")
            XCTFail("a rejected promise is an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("nope"), error.localizedDescription)
        }
    }

    func testNoNetworkFilesOrTimers() async throws {
        let script = """
        function run(d) {
          return [typeof fetch, typeof XMLHttpRequest, typeof WebSocket, typeof require,
                  typeof setTimeout, typeof document, typeof importScripts].join(",")
        }
        """
        let out = try await sandbox.run(script: script, data: "")
        XCTAssertEqual(out, "undefined,undefined,undefined,undefined,undefined,undefined,undefined")
    }

    func testFetchFailsRatherThanReachingTheNetwork() async {
        do {
            _ = try await sandbox.run(script: "function run(d) { return fetch('https://example.com') }", data: "")
            XCTFail("fetch must not exist")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("fetch"), error.localizedDescription)
        }
    }

    func testRunawayLoopIsStopped() async {
        var limits = JSSandbox.Limits()
        limits.cpuSeconds = 0.3
        limits.wallTimeout = .seconds(2)
        let tight = JSSandbox(limits: limits)
        let started = Date()
        do {
            _ = try await tight.run(script: "function run(d) { while (true) {} }", data: "")
            XCTFail("an endless loop can't finish")
        } catch {
            XCTAssertEqual(error as? JSSandbox.Failure, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testCPULimitIsEnforcedByTheEngine() {
        XCTAssertTrue(JSSandbox.enforcesCPULimit, "JavaScriptCore's execution time limit should be available")
    }

    func testSizeLimits() async {
        var limits = JSSandbox.Limits()
        limits.maxScriptBytes = 30
        limits.maxDataCharacters = 5
        limits.maxResultCharacters = 3
        let small = JSSandbox(limits: limits)
        do { _ = try await small.run(script: String(repeating: " ", count: 31), data: ""); XCTFail() } catch {
            XCTAssertEqual(error as? JSSandbox.Failure, .scriptTooLarge(30))
        }
        do { _ = try await small.run(script: "function run(d){}", data: "123456"); XCTFail() } catch {
            XCTAssertEqual(error as? JSSandbox.Failure, .dataTooLarge(5))
        }
        let out = try? await small.run(script: "function run(d){return d}", data: "abcde")
        XCTAssertEqual(out, "abc…", "the result is cut to its limit")
    }

    func testMissingEntryPointAndSyntaxErrors() async {
        do { _ = try await sandbox.run(script: "var x = 1", data: ""); XCTFail() } catch {
            XCTAssertEqual(error as? JSSandbox.Failure, .noEntryPoint)
        }
        do { _ = try await sandbox.run(script: "function run( {", data: ""); XCTFail() } catch {
            guard case .exception = error as? JSSandbox.Failure else { return XCTFail("\(error)") }
        }
    }

    func testEachRunGetsAFreshContext() async throws {
        let script = "var count = (typeof count === 'number') ? count + 1 : 1; function run(d) { return String(count) }"
        let first = try await sandbox.run(script: script, data: "")
        let second = try await sandbox.run(script: script, data: "")
        XCTAssertEqual(first, "1")
        XCTAssertEqual(second, "1", "nothing carries over between runs")
    }

    // MARK: The bundled scripts

    private func bundled(_ name: String) throws -> String {
        let root = try XCTUnwrap(Bundle.main.url(forResource: "Skills", withExtension: nil))
        return try String(contentsOf: root.appendingPathComponent("\(name)/scripts/index.js"), encoding: .utf8)
    }

    func testCalculateHashIsSHA256() async throws {
        let script = try bundled("calculate-hash")
        let out = try await sandbox.run(script: script, data: #"{"text": "hello world"}"#)
        XCTAssertEqual(out, #"{"result":"b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"}"#)
        let empty = try await sandbox.run(script: script, data: #"{"text": ""}"#)
        XCTAssertEqual(empty, #"{"result":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}"#)
        let unicode = try await sandbox.run(script: script, data: #"{"text": "héllo 👋"}"#)
        XCTAssertTrue(unicode.contains(Self.sha256("héllo 👋")), unicode)
    }

    func testWordCount() async throws {
        let out = try await sandbox.run(script: try bundled("word-count"), data: #"{"text": "One two three. Four!\nFive"}"#)
        XCTAssertTrue(out.contains(#""words":5"#), out)
        XCTAssertTrue(out.contains(#""sentences":3"#), out)
        XCTAssertTrue(out.contains(#""lines":2"#), out)
    }

    func testUnitTable() async throws {
        let script = try bundled("unit-table")
        let out = try await sandbox.run(script: script, data: #"{"from": "C", "to": "F", "start": 0, "end": 100, "step": 50}"#)
        XCTAssertTrue(out.contains("| 0 | 32 |"), out)
        XCTAssertTrue(out.contains("| 100 | 212 |"), out)
        let bad = try await sandbox.run(script: script, data: #"{"from": "kg", "to": "mi"}"#)
        XCTAssertTrue(bad.contains("can't convert kg to mi"), bad)
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
