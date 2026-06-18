import Foundation

// MARK: - SSE Stream Parser

/// Parses Server-Sent Events (SSE) from a streaming URLSession response
actor SSEParser {
    private var buffer = ""

    /// Process a new chunk of raw bytes and return any complete SSE events
    func process(data: Data) -> [SSEEvent] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        buffer += text
        return extractEvents()
    }

    private func extractEvents() -> [SSEEvent] {
        var events: [SSEEvent] = []
        var lines = buffer.components(separatedBy: "\n")

        // The last element may be incomplete — keep it in the buffer
        buffer = lines.removeLast()

        var currentEvent = SSEEvent()
        for line in lines {
            if line.isEmpty {
                // Empty line signals end of an event
                if currentEvent.data != nil {
                    events.append(currentEvent)
                }
                currentEvent = SSEEvent()
            } else if line.hasPrefix("data: ") {
                let data = String(line.dropFirst(6))
                currentEvent.data = (currentEvent.data ?? "") + data
            } else if line.hasPrefix("event: ") {
                currentEvent.type = String(line.dropFirst(7))
            } else if line.hasPrefix("id: ") {
                currentEvent.id = String(line.dropFirst(4))
            } else if line.hasPrefix(": ") {
                // Comment — ignore
            }
        }
        return events
    }

    func flush() -> [SSEEvent] {
        guard !buffer.isEmpty else { return [] }
        var events: [SSEEvent] = []
        let data = buffer
        buffer = ""
        var event = SSEEvent()
        if data.hasPrefix("data: ") {
            event.data = String(data.dropFirst(6))
            events.append(event)
        }
        return events
    }
}

struct SSEEvent {
    var type: String?
    var data: String?
    var id: String?
}

// MARK: - Gemini SSE Parser

/// Parses Gemini streaming SSE into text tokens
struct GeminiSSEParser {
    static func extractText(from event: SSEEvent) -> String? {
        guard let data = event.data, data != "[DONE]" else { return nil }
        guard let jsonData = data.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(GeminiStreamChunk.self, from: jsonData) else {
            return nil
        }
        return chunk.deltaText
    }
}

// MARK: - Private Compute SSE Parser

/// Parses the private compute server's streaming SSE into text deltas.
/// Wire format: `data: {"delta":"…"}` … terminated by `data: [DONE]`.
struct PrivateComputeSSEParser {
    static func extractText(from event: SSEEvent) -> String? {
        guard let data = event.data, data != "[DONE]" else { return nil }
        guard let jsonData = data.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(PCSStreamChunk.self, from: jsonData) else {
            return nil
        }
        return chunk.delta
    }
}
