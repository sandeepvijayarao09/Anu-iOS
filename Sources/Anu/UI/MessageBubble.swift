import SwiftUI

struct MessageBubble: View {
    let message: AgentMessage
    @State private var isExpanded = false

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
            Text(message.content)
                .padding(.horizontal, Space.comfy)
                .padding(.vertical, Space.base)
                .background(Color.anuAccent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: Radius.large))
                .textSelection(.enabled)

            Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.anuMeta)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Assistant Bubble

    private var assistantBubble: some View {
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

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.anuMeta)
                    .foregroundStyle(.tertiary)
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

    private var toolResultBubble: some View {
        HStack(alignment: .top, spacing: Space.snug) {
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
                        VStack(alignment: .leading, spacing: Space.hair) {
                            Text("Tool Result")
                                .font(.anuLabelStrong)
                                .foregroundStyle(.green)
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
                    .background(Color.green.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.medium)
                            .stroke(Color.green.opacity(0.3), lineWidth: 1)
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
