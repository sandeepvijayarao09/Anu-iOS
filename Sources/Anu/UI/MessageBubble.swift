import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct MessageBubble: View {
    let message: AgentMessage
    @State private var isExpanded = false
    @State private var saveAsWorkflow: WorkflowEditorTarget?

    var body: some View {
        HStack(alignment: .top, spacing: Space.snug) {
            if message.role == .user {
                Spacer(minLength: 60)
                userBubble
            } else if message.role == .assistant {
                assistantBubble
                Spacer(minLength: 60)
            } else if message.role == .toolCall {
                toolCallBubble
                Spacer(minLength: 20)
            } else if message.role == .toolResult {
                toolResultBubble
                Spacer(minLength: 20)
            } else if message.role == .system {
                systemBubble
            }
        }
    }

    // MARK: - User Bubble

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: Space.xs) {
            if let data = message.imageData, let image = Image(platformImageData: data) {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 180, maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.medium))
                    .accessibilityLabel("Attached image")
            }
            // Photos (a grid when several) and a PDF's pill, above the words.
            UserAttachmentsView(message: message)
            if let note = message.voiceNote {
                VoiceNoteBubble(note: note)
            } else if !message.content.isEmpty || (!message.carriesMedia && message.photosNoLongerKept == nil) {
                Text(message.content)
                    .padding(.horizontal, Space.comfy)
                    .padding(.vertical, Space.base)
                    .background(Color.anuAccent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.large))
                    .textSelection(.enabled)
            }

            Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.anuMeta)
                .foregroundStyle(.tertiary)
        }
        // Turn something you asked into a re-runnable workflow.
        .contextMenu {
            Button {
                saveAsWorkflow = .add(prompt: message.content)
            } label: {
                Label("Save as Workflow", systemImage: "play.square.stack")
            }
            .accessibilityIdentifier("saveAsWorkflowButton")
        }
        .sheet(item: $saveAsWorkflow) { target in
            WorkflowEditor(target: target)
        }
    }

    // MARK: - Assistant Bubble

    private var assistantBubble: some View {
        assistantBubbleBody
            // Copy, Share and Try again, like AI Edge Gallery's answer actions.
            .contextMenu {
                if !message.content.isEmpty {
                    Button { Self.copy(message.content) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .accessibilityIdentifier("copyAnswerButton")
                    ShareLink(item: message.content) { Label("Share", systemImage: "square.and.arrow.up") }
                }
                if isLatestAnswer, AgentOrchestrator.shared.retryableQuestion != nil {
                    Button {
                        Task { await AgentOrchestrator.shared.retryLastAnswer() }
                    } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                        .accessibilityIdentifier("tryAgainButton")
                }
            }
    }

    private var isLatestAnswer: Bool {
        AgentOrchestrator.shared.messages.last(where: { $0.role == .assistant })?.id == message.id
    }

    private static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private var assistantBubbleBody: some View {
        HStack(alignment: .top, spacing: Space.snug) {
            // Avatar
            Circle()
                .fill(Color.purple.gradient)
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "brain")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Anu")
                    .font(.anuLabelStrong)
                    .foregroundStyle(.secondary)

                // Generated image (Image Playground) — assistant turns can carry
                // an image just like user turns do for multimodal input.
                if let data = message.imageData, let image = Image(platformImageData: data) {
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.medium))
                        .accessibilityLabel("Generated image")
                }
                // Photos an answer found (a photo search), two to a row.
                if let photos = message.photos, !photos.isEmpty {
                    LazyVGrid(columns: [GridItem(.fixed(110), spacing: 4), GridItem(.fixed(110), spacing: 4)],
                              alignment: .leading, spacing: 4) {
                        ForEach(Array(photos.enumerated()), id: \.offset) { _, data in
                            if let image = Image(platformImageData: data) {
                                image.resizable().scaledToFill()
                                    .frame(width: 110, height: 110).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                            }
                        }
                    }
                    .accessibilityLabel("\(photos.count) photos found")
                }

                ZStack(alignment: .bottomTrailing) {
                    Text(message.content)
                        .padding(.horizontal, Space.comfy)
                        .padding(.vertical, Space.base)
                        .background(Color.anuFill6)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.large))
                        .textSelection(.enabled)

                    if message.isStreaming {
                        StreamingIndicator()
                            .padding(Space.tight)
                    }
                }

                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    ReasoningDisclosure(text: reasoning)
                }

                if let receipts = message.receipts, !receipts.isEmpty {
                    ReceiptList(receipts: receipts)
                }

                if let label = message.label {
                    Text(label)
                        .font(.anuMeta)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("answerLabel")
                }
                // The answering model; opens About this answer (ADR-071).
                AnswerCaption(message: message)
            }
        }
    }

    // MARK: - Tool Call Bubble

    private var toolCallBubble: some View {
        HStack(alignment: .top, spacing: Space.snug) {
            Circle()
                .fill(Color.orange.gradient)
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "wrench.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.spring(duration: 0.3)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: Space.hair) {
                            Text("Tool Call")
                                .font(.anuLabelStrong)
                                .foregroundStyle(.orange)
                            Text(message.toolCall?.name ?? message.content)
                                .font(.anuHeading)
                                .foregroundStyle(.primary)
                        }
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.anuLabel)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, Space.comfy)
                    .padding(.vertical, Space.base)
                    .background(Color.orange.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.medium)
                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Radius.medium))
                }
                .buttonStyle(.plain)

                if isExpanded, let tc = message.toolCall {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Arguments:")
                            .font(.anuLabelStrong)
                            .foregroundStyle(.secondary)
                        Text(tc.arguments.prettyJSON)
                            .font(.anuCode)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    .padding(Space.base)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.anuFill6)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                    .padding(.top, Space.xs)
                }
            }
        }
    }

    // MARK: - Tool Result Bubble

    /// What the broker's observation says happened, so a refused or failed
    /// call never wears the success check.
    private var resultKind: (title: String, icon: String, tint: Color) {
        let text = message.content
        if text.hasPrefix("Blocked (") { return ("Not run", "hand.raised.fill", .gray) }
        if text.hasPrefix("Tool error:") || text.hasPrefix("Error (") {
            return ("Failed", "exclamationmark", .red)
        }
        return ("Tool Result", "checkmark", .green)
    }

    private var toolResultBubble: some View {
        let kind = resultKind
        return HStack(alignment: .top, spacing: Space.snug) {
            Circle()
                .fill(kind.tint.gradient)
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: kind.icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.spring(duration: 0.3)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: Space.hair) {
                            Text(kind.title)
                                .font(.anuLabelStrong)
                                .foregroundStyle(kind.tint)
                            Text(isExpanded ? "Tap to collapse" : "Tap to expand")
                                .font(.anuLabel)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.anuLabel)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, Space.comfy)
                    .padding(.vertical, Space.base)
                    .background(kind.tint.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.medium)
                            .stroke(kind.tint.opacity(0.3), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Radius.medium))
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Text(message.content)
                        .font(.anuCode)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(Space.base)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.anuFill6)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                        .padding(.top, Space.xs)
                }
            }
        }
    }

    // MARK: - System Bubble

    private var systemBubble: some View {
        HStack {
            Spacer()
            Text(message.content)
                .font(.anuLabel)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Space.base)
                .padding(.vertical, Space.xs)
                .background(Color.anuFill5)
                .clipShape(Capsule())
            Spacer()
        }
    }
}

// MARK: - Streaming Indicator

struct StreamingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0
    let dotCount = 3

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(0..<dotCount, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
                    // Reduce Motion: hold the dots static rather than pulsing forever
                    .scaleEffect(reduceMotion ? 1.0 : (phase == i ? 1.3 : 0.8))
                    .animation(
                        reduceMotion ? nil
                        : .easeInOut(duration: 0.4).repeatForever(autoreverses: true).delay(Double(i) * 0.15),
                        value: phase
                    )
            }
        }
        .onAppear { phase = 0 }
        .accessibilityElement()
        .accessibilityLabel("Anu is responding")
    }
}

// MARK: - Receipts

/// What the broker actually did this turn, under the answer — in the tools'
/// own words, so the chat shows the truth whatever the model wrote (ADR-027).
struct ReceiptList: View {
    let receipts: [ActionReceipt]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(receipts) { receipt in
                HStack(alignment: .firstTextBaseline, spacing: Space.tight) {
                    Image(systemName: Self.icon(receipt.status))
                        .foregroundStyle(receipt.status == .failed ? Color.anuDestructive : Color.anuIcon)
                    Text(receipt.summary)
                        .foregroundStyle(Color.anuInk)
                    + Text(" · " + receipt.statusLabel)
                        .foregroundStyle(.secondary)
                }
                .font(.anuLabel)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, Space.comfy)
        .accessibilityIdentifier("receipts")
    }

    static func icon(_ status: ActionReceipt.Status) -> String {
        switch status {
        case .done: return "checkmark.circle"
        case .declined: return "xmark.circle"
        case .noAnswer: return "clock"
        case .blocked: return "nosign"
        case .failed: return "exclamationmark.triangle"
        }
    }
}
