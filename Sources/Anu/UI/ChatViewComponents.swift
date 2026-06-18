import SwiftUI
import PhotosUI

// MARK: - Status Bar

struct StatusBar: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .overlay {
                    if isAnimating {
                        Circle()
                            .stroke(statusColor, lineWidth: 1)
                            .scaleEffect(1.5)
                            .opacity(0.5)
                    }
                }

            Text(status.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Image(systemName: status.iconName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    var statusColor: Color {
        switch status {
        case .idle: return .green
        case .planning, .thinking, .streaming, .verifying: return .blue
        case .callingTool: return .orange
        case .escalating: return .purple
        case .error: return .red
        }
    }

    var isAnimating: Bool {
        switch status {
        case .planning, .thinking, .streaming, .callingTool, .escalating, .verifying: return true
        default: return false
        }
    }
}

// MARK: - Input Bar

struct InputBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let isThinking: Bool
    let isRecording: Bool
    @Binding var showTrace: Bool
    let hasTrace: Bool
    @Binding var photoItem: PhotosPickerItem?
    @State private var actionPulse = 0
    let onSend: () -> Void
    let onClear: () -> Void
    let onStop: () -> Void
    let onMic: () -> Void
    let onCamera: () -> Void
    let onCreateImage: () -> Void

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            // Trace toggle
            if hasTrace {
                Button {
                    withAnimation(.spring(duration: 0.3)) {
                        showTrace.toggle()
                    }
                } label: {
                    Image(systemName: showTrace ? "brain.fill" : "brain")
                        .foregroundStyle(showTrace ? .blue : .secondary)
                        .font(.system(size: 18))
                }
                .accessibilityLabel(showTrace ? "Hide reasoning trace" : "Show reasoning trace")
                .accessibilityIdentifier("traceToggle")
            }

            // Clear button
            Button {
                onClear()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 18))
            }
            .accessibilityLabel("Clear conversation")
            .accessibilityIdentifier("clearButton")

            // Photo attach (multimodal input)
            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 18))
            }
            .accessibilityLabel("Attach an image")
            .accessibilityIdentifier("photoButton")

            // Live camera — point-and-ask Visual Intelligence
            Button {
                onCamera()
            } label: {
                Image(systemName: "camera")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 18))
            }
            .accessibilityLabel("Take a photo to ask about")
            .accessibilityIdentifier("cameraButton")

            // Create an image (Apple Image Playground)
            Button {
                onCreateImage()
            } label: {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 18))
            }
            .accessibilityLabel("Create an image")
            .accessibilityIdentifier("createImageButton")

            // Text input (live dictation streams in here too)
            TextField(isRecording ? "Listening…" : "Message…", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused(isFocused)
                .submitLabel(.send)
                .onSubmit {
                    onSend()
                }
                .disabled(isThinking)
                .accessibilityIdentifier("messageField")

            // Primary action — voice-first: mic until there's text or work
            if isThinking {
                Button { actionPulse += 1; onStop() } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("Stop generating")
                .accessibilityIdentifier("stopButton")
            } else if isRecording {
                Button { actionPulse += 1; onMic() } label: {
                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.red)
                        // Reduce Motion: the red tint alone signals recording;
                        // skip the continuous pulse
                        .symbolEffect(.pulse, isActive: !reduceMotion)
                }
                .accessibilityLabel("Stop recording and send")
                .accessibilityIdentifier("micButton")
            } else if hasText {
                Button { actionPulse += 1; onSend() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.blue)
                }
                .accessibilityLabel("Send message")
                .accessibilityIdentifier("sendButton")
            } else {
                Button { actionPulse += 1; onMic() } label: {
                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.blue)
                }
                .accessibilityLabel("Start voice input")
                .accessibilityIdentifier("micButton")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background)
        // Native iOS 17 haptics on every primary action
        .sensoryFeedback(.impact(flexibility: .soft), trigger: actionPulse)
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 64))
                .foregroundStyle(.blue.gradient)

            Text("Anu")
                .font(.title2.bold())

            Text("An on-device agentic AI powered by Gemma 4B with Gemini escalation")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 8) {
                CapabilityRow(icon: "cpu", text: "Local inference with Gemma 4B")
                CapabilityRow(icon: "arrow.up.circle", text: "Escalates complex tasks to Gemini")
                CapabilityRow(icon: "wrench", text: "Uses tools: calculator, web search")
                CapabilityRow(icon: "brain", text: "ReAct reasoning loop")
            }
            .padding(.top, 8)
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
    }
}

struct CapabilityRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
