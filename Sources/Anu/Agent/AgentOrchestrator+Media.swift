import Foundation

// Photos and PDFs in the chat (Android parity: ADR-075, ADR-082, ADR-094,
// ADR-095), split out of the AgentOrchestrator core.
extension AgentOrchestrator {
    /// One user turn with a single attached image (the older entry point).
    func run(userMessage: String, imageData: Data?) async {
        await run(userMessage: userMessage, attachments: MessageAttachments(photos: imageData.map { [$0] } ?? []))
    }

    /// What the egress gate says when a photo or PDF is in view.
    static let mediaStaysOnPhone =
        "A photo or PDF is in view, so this stays on the phone: it never goes to the cloud. Answer on the device."

    /// The history as the model reads it: a PDF's text after its message's
    /// words, and a note for photos sent with no words. Ids are kept, so the
    /// window it gives can be matched back to the chat.
    nonisolated static func modelView(_ history: [AgentMessage]) -> [AgentMessage] {
        history.map { message in
            guard message.role == .user, message.carriesMedia else { return message }
            var copy = message
            let typed = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            var parts: [String] = typed ? [message.content] : []
            if let document = message.document {
                parts.append(Documents.block(document, typed: typed))
            } else if !typed {
                let count = message.pictures.count
                parts.append("The user sent \(count == 1 ? "a photo" : "\(count) photos") with no words: say briefly what \(count == 1 ? "it shows" : "they show").")
            }
            copy.content = parts.joined(separator: "\n\n")
            return copy
        }
    }

    /// Whether the model's view of `history` holds a photo or a PDF.
    nonisolated static func mediaInView(_ history: [AgentMessage]) -> Bool {
        ConversationWindow.windowed(modelView(history)).contains(where: \.carriesMedia)
    }

    var hasMediaInView: Bool { Self.mediaInView(conversationHistory) }

    /// The egress gate for media (MEDIA-1): with a photo or PDF in view, no
    /// call that sends text off the phone runs, whatever the route decided. It
    /// refuses before anything is sent, so nothing reaches the Privacy Ledger.
    func mediaEgressRefusal(for info: ToolCallInfo) -> String? {
        guard hasMediaInView else { return nil }
        if info.name.hasPrefix("escalate_to") { return Self.mediaStaysOnPhone }
        if let tool = toolRegistry.tool(named: info.name), case .external = tool.sideEffect { return Self.mediaStaysOnPhone }
        return nil
    }

    /// Reads a long PDF in pieces on the phone (ADR-095) and keeps the notes
    /// for the question with its message: each piece in a conversation of its
    /// own with no history, memory or tools, at most 200 tokens of notes.
    func readDocumentInPieces(messageID: UUID, pages: [String], question: String) async {
        guard let index = conversationHistory.lastIndex(where: { $0.id == messageID }),
              var document = conversationHistory[index].document,
              !document.whole, !document.pictures, !pages.isEmpty else { return }
        let pieces = Documents.split(pages)
        guard !pieces.isEmpty else { return }

        let progress = AgentMessage.system("Reading \(document.name)…")
        appendMessage(progress)
        defer { messages.removeAll { $0.id == progress.id } }

        var config = GenerationConfig.deterministic
        config.maxNewTokens = Documents.noteTokens
        var notes: [String] = []
        for piece in pieces {
            if Task.isCancelled { return }
            if let at = messages.firstIndex(where: { $0.id == progress.id }) {
                messages[at].content = "Reading \(document.name)… page \(piece.last) of \(document.read)"
            }
            await model.resetSession()
            let prompt = GemmaChatTemplate.format(
                messages: [.user(Documents.pieceMessage(name: document.name, piece: piece, question: question))],
                tools: [],
                systemPromptOverride: Documents.pieceInstruction)
            var said = ""
            do {
                for await token in try await model.generate(prompt: prompt, config: config) {
                    if Task.isCancelled { break }
                    said += token
                }
            } catch {
                continue
            }
            if let note = Documents.note(piece, answer: said) { notes.append(note) }
            reasoningSteps.append(ReasoningStep(
                iteration: 0, thought: "\(piece.pages) of \(document.name): \(said.prefix(80))", action: "Read PDF piece"))
        }
        // The pieces ran in conversations of their own; the chat rebuilds its own.
        await model.resetSession()
        document.text = Documents.notes(notes)
        conversationHistory[index].document = document
        if let at = messages.firstIndex(where: { $0.id == messageID }) { messages[at].document = document }
    }
}
