import XCTest
@testable import GemmaAgent

final class GemmaTokenizerTests: XCTestCase {
    private var fixtureURL: URL!

    override func setUpWithError() throws {
        // Minimal HF tokenizer.json fixture (BPE vocab layout).
        // ▁ is U+2581, SentencePiece's word-boundary marker.
        let json = """
        {"added_tokens":[{"id":0,"content":"<pad>"},{"id":1,"content":"<eos>"},{"id":2,"content":"<bos>"}],
         "model":{"type":"BPE","vocab":{"<pad>":0,"<eos>":1,"<bos>":2,"\u{2581}hello":10,"\u{2581}world":11,"\u{2581}":12,"h":13,"i":14,"<0xE2>":20,"<0x9C>":21,"<0x93>":22}}}
        """
        fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenizer-fixture-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: fixtureURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixtureURL)
    }

    func testSpecialTokenIdsFromAddedTokens() throws {
        let tok = try GemmaTokenizer(contentsOf: fixtureURL)
        XCTAssertEqual(tok.bosTokenId, 2)
        XCTAssertEqual(tok.eosTokenId, 1)
        XCTAssertEqual(tok.padTokenId, 0)
    }

    func testEncodePrependsBOSAndMatchesGreedily() throws {
        let tok = try GemmaTokenizer(contentsOf: fixtureURL)
        let ids = tok.encode("hello world hi")
        XCTAssertEqual(ids.first, tok.bosTokenId)
        // ▁hello ▁world ▁ h i
        XCTAssertEqual(Array(ids.dropFirst()), [10, 11, 12, 13, 14])
    }

    func testDecodeRoundTrip() throws {
        let tok = try GemmaTokenizer(contentsOf: fixtureURL)
        let decoded = tok.decode(tok.encode("hello world hi"))
        XCTAssertEqual(decoded, " hello world hi")
    }

    func testByteFallbackDecodesMultiByteCharacter() throws {
        let tok = try GemmaTokenizer(contentsOf: fixtureURL)
        // ✓ (U+2713) is the UTF-8 byte sequence E2 9C 93
        XCTAssertEqual(tok.decode([20, 21, 22]), "\u{2713}")
    }

    func testSpecialTokensSkippedInDecode() throws {
        let tok = try GemmaTokenizer(contentsOf: fixtureURL)
        XCTAssertEqual(tok.decode([2, 10, 1]), " hello")
    }

    func testInvalidFileThrows() {
        let bad = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).json")
        XCTAssertThrowsError(try GemmaTokenizer(contentsOf: bad))
    }
}
