import SwiftUI

/// Glass-box timeline: the agent's reasoning rendered as a vertical
/// plan → step → tool/observation → critic timeline. Each node is colored by
/// `ReasoningStepKind`; a latency pill shows how long each step took relative to
/// the previous one. Pure visualization over `AgentOrchestrator.reasoningSteps`.
struct AgentTraceView: View {
    let steps: [ReasoningStep]
    @State private var expandedStepId: UUID?

    /// Pairs each step with the latency since the previous step (nil for the first).
    private var timeline: [(step: ReasoningStep, latency: TimeInterval?)] {
        steps.enumerated().map { index, step in
            let latency = index > 0 ? step.timestamp.timeIntervalSince(steps[index - 1].timestamp) : nil
            return (step, latency)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "brain")
                    .foregroundStyle(.blue)
                Text("Agent Reasoning Trace")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(steps.count) step\(steps.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(timeline.enumerated()), id: \.element.step.id) { index, entry in
                        TimelineRow(
                            step: entry.step,
                            latency: entry.latency,
                            isFirst: index == 0,
                            isLast: index == timeline.count - 1,
                            isExpanded: expandedStepId == entry.step.id
                        ) {
                            withAnimation(.spring(duration: 0.3)) {
                                expandedStepId = expandedStepId == entry.step.id ? nil : entry.step.id
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Timeline Row

private struct TimelineRow: View {
    let step: ReasoningStep
    let latency: TimeInterval?
    let isFirst: Bool
    let isLast: Bool
    let isExpanded: Bool
    let onTap: () -> Void

    private var nodeColor: Color { TraceStyle.color(step.kind.colorName) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Leading rail: connecting line + colored node
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : Color(.systemGray4))
                    .frame(width: 2, height: 8)
                ZStack {
                    Circle()
                        .fill(nodeColor)
                        .frame(width: 22, height: 22)
                    Image(systemName: step.kind.iconName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
                Rectangle()
                    .fill(isLast ? Color.clear : Color(.systemGray4))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 22)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Button(action: onTap) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(.caption.bold())
                                .foregroundStyle(.primary)
                            Spacer(minLength: 4)
                            if let latency {
                                Text(TraceStyle.latencyLabel(latency))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(isExpanded ? nil : 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        if !step.thought.isEmpty {
                            TraceSection(label: "Thought", content: step.thought, color: nodeColor)
                        }
                        if let action = step.action {
                            TraceSection(label: "Action", content: action, color: .orange)
                        }
                        if let observation = step.observation {
                            TraceSection(label: "Observation", content: observation, color: .green)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            .padding(.bottom, 6)
        }
    }

    /// Headline derived from the step kind (and specialist / iteration).
    private var title: String {
        switch step.kind {
        case .route: return "Route"
        case .memory: return "Personalization"
        case .plan: return "Plan"
        case .specialistStep:
            let who = step.specialist.map { " · \($0)" } ?? ""
            return "Step \(step.iteration)\(who)"
        case .tool: return step.action ?? "Tool"
        case .critic: return "Critic"
        case .final: return "Final answer"
        case .thought: return "Thinking \(step.iteration)"
        }
    }

    /// One-line preview shown under the title. For tool/route/plan/critic steps
    /// the action is the most informative; otherwise the thought.
    private var subtitle: String? {
        switch step.kind {
        case .tool, .thought, .final:
            return step.thought.isEmpty ? step.action : step.thought
        default:
            return step.action ?? (step.thought.isEmpty ? nil : step.thought)
        }
    }
}

// MARK: - Trace Section

private struct TraceSection: View {
    let label: String
    let content: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
                .tracking(1)

            Text(content)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Style helpers

enum TraceStyle {
    /// Maps the framework-free color name on `ReasoningStepKind` to a SwiftUI Color.
    static func color(_ name: String) -> Color {
        switch name {
        case "indigo": return .indigo
        case "teal": return .teal
        case "blue": return .blue
        case "purple": return .purple
        case "orange": return .orange
        case "green": return .green
        case "red": return .red
        default: return .blue
        }
    }

    /// Human latency label: "120ms" under a second, else "1.4s".
    static func latencyLabel(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded()))ms" : String(format: "%.1fs", seconds)
    }
}
