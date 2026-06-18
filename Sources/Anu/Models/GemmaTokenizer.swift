import Foundation

/// Tokenizer that loads a HuggingFace `tokenizer.json` exported by
/// convert_gemma_coreml.py (saved in the gemma4b_tokenizer directory).
///
/// Supports both vocab layouts found in tokenizer.json:
///   - BPE:     "model": { "vocab": { "token": id, ... } }
///   - Unigram: "model": { "vocab": [ ["token", score], ... ] }
///
/// Encoding is greedy longest-match over the vocab with byte fallback
/// (`<0xNN>` tokens). This is an approximation of SentencePiece, accurate
/// enough for chat-style prompts; exactness improves nothing unless the
/// vocab merges are also replayed.
final class GemmaTokenizer: Tokenizer {
    private let tokenToId: [String: Int]
    private let idToToken: [Int: String]
    private let maxTokenLength: Int

    let bosTokenId: Int
    let eosTokenId: Int
    let padTokenId: Int

    /// SentencePiece uses ▁ (U+2581) to mark word boundaries.
    private static let spaceMarker = "\u{2581}"

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json["model"] as? [String: Any] else {
            throw ModelError.tokenizationFailed
        }

        var vocab: [String: Int] = [:]
        if let dict = model["vocab"] as? [String: Int] {
            // BPE layout
            vocab = dict
        } else if let array = model["vocab"] as? [[Any]] {
            // Unigram layout: index in the array is the token id
            for (id, entry) in array.enumerated() {
                if let token = entry.first as? String {
                    vocab[token] = id
                }
            }
        } else {
            throw ModelError.tokenizationFailed
        }

        self.tokenToId = vocab
        self.idToToken = Dictionary(uniqueKeysWithValues: vocab.map { ($1, $0) })
        self.maxTokenLength = vocab.keys.map(\.count).max() ?? 1

        // Special token ids from added_tokens, with Gemma defaults as fallback
        var bos = 2, eos = 1, pad = 0
        if let added = json["added_tokens"] as? [[String: Any]] {
            for entry in added {
                guard let content = entry["content"] as? String,
                      let id = entry["id"] as? Int else { continue }
                switch content {
                case "<bos>": bos = id
                case "<eos>": eos = id
                case "<pad>": pad = id
                default: break
                }
            }
        }
        self.bosTokenId = bos
        self.eosTokenId = eos
        self.padTokenId = pad
    }

    // MARK: - Encode

    func encode(_ text: String) -> [Int] {
        var ids: [Int] = [bosTokenId]
        // SentencePiece pre-processing: spaces become the ▁ marker
        let normalized = Self.spaceMarker + text.replacingOccurrences(of: " ", with: Self.spaceMarker)
        let chars = Array(normalized)
        var pos = 0

        while pos < chars.count {
            // Greedy longest match against the vocab
            var matched = false
            let maxLen = min(maxTokenLength, chars.count - pos)
            for length in stride(from: maxLen, through: 1, by: -1) {
                let candidate = String(chars[pos..<(pos + length)])
                if let id = tokenToId[candidate] {
                    ids.append(id)
                    pos += length
                    matched = true
                    break
                }
            }
            if !matched {
                // Byte fallback: encode the character's UTF-8 bytes as <0xNN>
                let char = chars[pos]
                for byte in String(char).utf8 {
                    let byteToken = String(format: "<0x%02X>", byte)
                    if let id = tokenToId[byteToken] {
                        ids.append(id)
                    }
                }
                pos += 1
            }
        }
        return ids
    }

    // MARK: - Decode

    func decode(_ tokens: [Int]) -> String {
        var result = ""
        var pendingBytes: [UInt8] = []

        func flushBytes() {
            guard !pendingBytes.isEmpty else { return }
            result += String(decoding: pendingBytes, as: UTF8.self)
            pendingBytes = []
        }

        for id in tokens {
            guard let token = idToToken[id] else { continue }
            // Byte fallback token <0xNN> — accumulate to decode multi-byte chars
            if token.count == 6, token.hasPrefix("<0x"), token.hasSuffix(">"),
               let byte = UInt8(token.dropFirst(3).dropLast(), radix: 16) {
                pendingBytes.append(byte)
                continue
            }
            flushBytes()
            if token == "<bos>" || token == "<eos>" || token == "<pad>" { continue }
            result += token.replacingOccurrences(of: Self.spaceMarker, with: " ")
        }
        flushBytes()
        return result
    }
}
