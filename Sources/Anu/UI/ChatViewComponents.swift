import SwiftUI
import PhotosUI

// MARK: - Status Bar

struct StatusBar: View {
    let status: AgentStatus
    /// Why the answer is waiting, once it has waited a second (ADR-074).
    var waitNote: String? = nil

    var body: some View {
        HStack(spacing: Space.tight) {
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

            Text(waitNote ?? status.displayText)
                .font(.anuLabel)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("statusText")

            Spacer()

            Image(systemName: status.iconName)
                .font(.anuLabel)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.comfy)
        .padding(.vertical, Space.snug)
        .background(.ultraThinMaterial)
    }

    var statusColor: Color {
        switch status {
        case .idle: return .green
        case .planning, .thinking, .streaming, .verifying: return .anuAccent
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
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let isThinking: Bool
    let isRecording: Bool
    /// Live state of the voice orb — the composer's one accent-coloured element.
    let orbState: VoiceOrbState
    let orbLevel: Double
    @Binding var showTrace: Bool
    let hasTrace: Bool
    @Binding var photoItems: [PhotosPickerItem]
    /// How many more photos this message takes (four at most, ADR-094).
    var photoLimit: Int = MessageAttachments.maxPhotos
    /// Photos or a PDF wait in the composer, so Send works without words.
    var hasAttachments: Bool = false
    @State private var actionPulse = 0
    @State private var showPhotoPicker = false
    @State private var confirmingClear = false
    let onSend: () -> Void
    let onClear: () -> Void
    let onStop: () -> Void
    let onMic: () -> Void
    let onCamera: () -> Void
    let onCreateImage: () -> Void
    /// Live camera with object boxes (nil hides the item, e.g. on the Mac).
    var onLiveCamera: (() -> Void)? = nil
    /// Opens the file picker for one PDF (ADR-095).
    var onPDF: (() -> Void)? = nil
    /// Records a voice note (ADR-078). Optional so other call sites compile.
    var onVoiceNote: (() -> Void)? = nil
    /// Opens the Screenshots picker to ask about a screen (ADR-083's iOS form).
    var onAskAboutScreen: (() -> Void)? = nil

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // Five same-weight accent icons used to sit in this row, so the eye had no
    // primary to land on and a destructive Clear sat a thumb-width from the
    // send button. Now: one neutral "+" for everything occasional, the field,
    // and a single accented action. Three targets instead of seven.
    var body: some View {
        HStack(spacing: Space.base) {
            attachmentMenu

            TextField(isRecording ? "Listening…" : "Message", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.anuBody)
                .lineLimit(1...5)
                .focused(isFocused)
                .submitLabel(.send)
                .onSubmit(onSend)
                .disabled(isThinking)
                .padding(.horizontal, Space.base)
                .padding(.vertical, Space.snug)
                .background(Color.anuFill6, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.anuHairline, lineWidth: 1))
                .accessibilityIdentifier("messageField")

            primaryAction
        }
        .padding(.horizontal, Space.comfy)
        .padding(.vertical, Space.base)
        .background(.background)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                      maxSelectionCount: max(1, photoLimit), matching: .images)
        // Clearing can't be undone, and it now sits one tap from Photo
        // Library. Confirming costs a moment; losing a conversation doesn't
        // have an equivalent recovery.
        .confirmationDialog("Clear this conversation?",
                            isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Conversation", role: .destructive, action: onClear)
                .accessibilityIdentifier("confirmClearButton")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The messages in this chat will be deleted. This can't be undone.")
        }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: actionPulse)
    }

    /// Everything occasional, behind one neutral affordance. Clear is declared
    /// last, past a divider — in an upward-opening menu iOS puts that farthest
    /// from the thumb, so the destructive item isn't on the path to "Photo".
    private var attachmentMenu: some View {
        Menu {
            Button { showPhotoPicker = true } label: {
                Label(photoLimit < MessageAttachments.maxPhotos ? "Photo Library (\(photoLimit) more)" : "Photo Library",
                      systemImage: "photo")
            }
            .disabled(photoLimit == 0)
            .accessibilityIdentifier("photoButton")

            if let onAskAboutScreen {
                Button(action: onAskAboutScreen) {
                    Label("Ask About My Screen", systemImage: "rectangle.dashed.and.paperclip")
                }
                .disabled(photoLimit == 0)
                .accessibilityIdentifier("askAboutScreenButton")
            }

            Button(action: onCamera) {
                Label("Take Photo", systemImage: "camera")
            }
            .disabled(photoLimit == 0)
            .accessibilityIdentifier("cameraButton")

            if let onLiveCamera {
                Button(action: onLiveCamera) {
                    Label("Live Camera", systemImage: "viewfinder")
                }
                .accessibilityIdentifier("liveCameraButton")
            }
            if let onPDF {
                Button(action: onPDF) {
                    Label("PDF", systemImage: "doc.richtext")
                }
                .accessibilityIdentifier("pdfButton")
            }

            Button(action: onCreateImage) {
                Label("Create Image", systemImage: "wand.and.stars")
            }
            .accessibilityIdentifier("createImageButton")

            if let onVoiceNote {
                Button(action: onVoiceNote) {
                    Label("Voice Note", systemImage: "waveform")
                }
                .accessibilityIdentifier("voiceNoteButton")
            }

            if hasTrace {
                Divider()
                Button {
                    withAnimation(.spring(duration: 0.3)) { showTrace.toggle() }
                } label: {
                    Label(showTrace ? "Hide Reasoning" : "Show Reasoning",
                          systemImage: showTrace ? "brain.fill" : "brain")
                }
                .accessibilityIdentifier("traceToggle")
            }

            Divider()
            Button(role: .destructive) { confirmingClear = true } label: {
                Label("Clear Conversation", systemImage: "trash")
            }
            .accessibilityIdentifier("clearButton")
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.anuIcon)
                .frame(width: 32, height: 32)
                .background(Color.anuFill6, in: Circle())
        }
        .accessibilityLabel("More actions")
        .accessibilityIdentifier("composerMenu")
    }

    /// Exactly one accented control, and it changes meaning with state rather
    /// than adding neighbours: stop while working, send once there's text,
    /// otherwise the voice orb.
    @ViewBuilder
    private var primaryAction: some View {
        if isThinking {
            Button { actionPulse += 1; onStop() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.anuDestructive, in: Circle())
            }
            .accessibilityLabel("Stop generating")
            .accessibilityIdentifier("stopButton")
        } else if hasText || hasAttachments {
            Button { actionPulse += 1; onSend() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.anuAccent, in: Circle())
            }
            .accessibilityLabel("Send message")
            .accessibilityIdentifier("sendButton")
        } else {
            Button { actionPulse += 1; onMic() } label: {
                VoiceOrb(state: orbState, level: orbLevel, size: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRecording ? "Stop recording and send" : "Open voice mode")
            .accessibilityIdentifier("micButton")
        }
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Fires with the prompt text when a suggestion is tapped. The chat sends
    /// it as if the user had typed it.
    let onSelect: (String) -> Void
    /// Set when the model failed to load — the one "next step" worth showing
    /// here, since nothing else on this screen will work until it's resolved.
    var loadFailure: String?
    var onOpenSettings: (() -> Void)?
    /// The model answering on this phone, by its short name.
    var modelName = "Gemma 4"

    /// Starter prompts. Each is self-contained so tapping it produces a real
    /// answer, and each exercises a tool Anu actually has — calendar,
    /// reminders, calculator, unit conversion — rather than describing one.
    private struct Suggestion: Identifiable {
        let id = UUID()
        let icon: String
        let text: String
    }
    private let suggestions: [Suggestion] = [
        Suggestion(icon: "calendar", text: "What's on my calendar today?"),
        Suggestion(icon: "checklist", text: "Remind me to call mom at 6pm"),
        Suggestion(icon: "function", text: "What's 18% of 47.50?"),
        Suggestion(icon: "arrow.left.arrow.right", text: "How many km is 26.2 miles?"),
    ]


    /// "Answers on this device with Gemma 4 · …". Apple's model is named
    /// Apple Intelligence here, so it never reads "on-device with Apple on-device".
    static func footnote(_ modelName: String) -> String {
        var name = modelName
        if name.hasPrefix("Apple") { name = "Apple Intelligence" }
        return "Answers on this device with \(name) · goes to the cloud only when you ask"
    }

    var body: some View {
        // One focal point, one alignment edge. The four capability bullets
        // that used to sit here described what the suggestions below already
        // demonstrate — removing them lets the invitation lead, and drops the
        // screen from four competing centres of attention to one.
        VStack(alignment: .leading, spacing: Space.loose) {
            VStack(alignment: .leading, spacing: Space.base) {
                HStack(spacing: Space.snug) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.anuAccent)
                    Text("Anu")
                        .font(.anuHeading)
                        .foregroundStyle(.secondary)
                }

                Text("What can I help with?")
                    .font(.largeTitle.weight(.semibold))
                    // Large display type set at body line-height floats; pull
                    // it tighter so the line reads as one object.
                    .lineSpacing(-2)
                    .foregroundStyle(Color.anuInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let loadFailure {
                nextStep(loadFailure)
            } else {
                suggestionGrid
            }

            // Positioning, demoted to a footnote. It's worth saying once; it
            // was not worth four accent-coloured bullets above the fold.
            Text(EmptyStateView.footnote(modelName))
                .font(.anuLabel)
                // `.tertiary` at 13pt on a black background measured well under
                // WCAG AA in dark mode. `.secondary` keeps it demoted without
                // making it unreadable.
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Space.stage)
        .padding(.bottom, Space.comfy)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var suggestionGrid: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            // Two columns of ~180pt can't hold accessibility-sized text —
            // it wraps to a word per line. Fall back to one column there.
            LazyVGrid(columns: suggestionColumns, spacing: Space.snug) {
                ForEach(suggestions) { suggestion in
                    Button {
                        onSelect(suggestion.text)
                    } label: {
                        SuggestionCard(icon: suggestion.icon, text: suggestion.text)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("suggestion")
                }
            }
        }
    }

    private var suggestionColumns: [GridItem] {
        typeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: Space.snug), GridItem(.flexible(), spacing: Space.snug)]
    }

    /// Shown instead of suggestions when there's no working model — offering
    /// prompts that can't run would just produce four identical errors.
    private func nextStep(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Label("No model loaded", systemImage: "exclamationmark.triangle.fill")
                .font(.anuHeading)
                .foregroundStyle(.orange)
            Text(reason)
                .font(.anuLabel)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let onOpenSettings {
                Button("Open Model settings", action: onOpenSettings)
                    .font(.anuLabelStrong)
                    .padding(.top, Space.hair)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .anuCard()
        .accessibilityIdentifier("modelNextStep")
    }
}

private struct SuggestionCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let icon: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.anuIcon)
            Text(text)
                .font(.anuLabel)
                .foregroundStyle(Color.anuInk)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity,
               minHeight: typeSize.isAccessibilitySize ? 0 : 72,
               alignment: .topLeading)
        .anuCard()
    }
}
