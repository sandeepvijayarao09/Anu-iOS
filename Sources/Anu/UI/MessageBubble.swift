import SwiftUI

struct MessageBubble: View {
    let message: AgentMessage
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
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
        VStack(alignment: .trailing, spacing: 4) {
            if let data = message.imageData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 180, maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("Attached image")
            }
            Text(message.content)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .textSelection(.enabled)

            Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Assistant Bubble

    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            // Avatar
            Circle()
                .fill(Color.purple.gradient)
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "brain")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text("Anu")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                // Generated image (Image Playground) — assistant turns can carry
                // an image just like user turns do for multimodal input.
                if let data = message.imageData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .accessibilityLabel("Generated image")
                }

                ZStack(alignment: .bottomTrailing) {
                    Text(message.content)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .textSelection(.enabled)

                    if message.isStreaming {
                        StreamingIndicator()
                            .padding(6)
                    }
                }

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Tool Call Bubble

    private var toolCallBubble: some View {
        HStack(alignment: .top, spacing: 8) {
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tool Call")
                                .font(.caption.bold())
                                .foregroundStyle(.orange)
                            Text(message.toolCall?.name ?? message.content)
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                        }
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                if isExpanded, let tc = message.toolCall {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Arguments:")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(tc.arguments.prettyJSON)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Tool Result Bubble

    private var toolResultBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.green.gradient)
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "checkmark")
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tool Result")
                                .font(.caption.bold())
                                .foregroundStyle(.green)
                            Text(isExpanded ? "Tap to collapse" : "Tap to expand")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.green.opacity(0.3), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Text(message.content)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - System Bubble

    private var systemBubble: some View {
        HStack {
            Spacer()
            Text(message.content)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(.systemGray5))
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
        HStack(spacing: 3) {
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
