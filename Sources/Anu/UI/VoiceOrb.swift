import SwiftUI

// MARK: - Voice orb
//
// A living sphere that stands in for Anu's voice. It reacts to real signal —
// microphone amplitude while you talk, word cadence while Anu talks back —
// rather than animating on a fixed loop, so the motion always means something.
//
// One view serves both sizes: a 36pt button in the input bar and a 260pt
// centrepiece in voice mode. Everything scales off `size`, so there's a single
// place to tune the look.

/// What the orb is reacting to. Drives palette and motion character.
enum VoiceOrbState: Equatable {
    case idle
    case listening
    case thinking
    case speaking

    /// Two-stop palette, warm end first. Deliberately narrow — the state reads
    /// from hue, not from a different shape or a different animation gimmick.
    var palette: (Color, Color) {
        switch self {
        case .idle:
            return (Color(red: 0.30, green: 0.56, blue: 1.00), Color(red: 0.33, green: 0.33, blue: 0.85))
        case .listening:
            return (Color(red: 0.22, green: 0.80, blue: 1.00), Color(red: 0.20, green: 0.46, blue: 1.00))
        case .thinking:
            return (Color(red: 0.52, green: 0.38, blue: 0.98), Color(red: 0.36, green: 0.30, blue: 0.88))
        case .speaking:
            return (Color(red: 0.92, green: 0.34, blue: 0.86), Color(red: 0.56, green: 0.30, blue: 0.96))
        }
    }

    /// How fast the silhouette churns. Listening is alert, thinking is a slow
    /// simmer, speaking rides between the two.
    var churn: Double {
        switch self {
        case .idle: return 0.35
        case .listening: return 1.30
        case .thinking: return 0.70
        case .speaking: return 1.05
        }
    }

    /// Baseline wobble before live amplitude is added, as a fraction of radius.
    var baseWobble: Double {
        switch self {
        case .idle: return 0.018
        case .listening: return 0.030
        case .thinking: return 0.045
        case .speaking: return 0.035
        }
    }

    var showsRipples: Bool {
        self == .listening || self == .speaking
    }
}

/// A sphere that breathes with `level` (0...1 live amplitude).
struct VoiceOrb: View {
    var state: VoiceOrbState
    var level: Double
    var size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOnScreen = false

    /// Amplitude actually used for geometry. Clamped, and eased so a shout
    /// doesn't slam the orb against the edge of its frame.
    private var amplitude: Double {
        let clamped = min(max(level, 0), 1)
        return pow(clamped, 0.7)
    }

    /// Whether the timeline should produce frames. The orb rests when idle and
    /// silent, under Reduce Motion, and whenever it isn't on screen — so the
    /// chat's input-bar orb draws nothing while you read. (On Anu Android the
    /// idle breath redrew the screen at 120 Hz, 43% of a CPU core: ADR-063.)
    private var animates: Bool {
        isOnScreen && !reduceMotion && !(state == .idle && amplitude < 0.01)
    }

    var body: some View {
        // A paused timeline still draws once, so a resting orb keeps its
        // palette and shape; it just doesn't churn.
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animates)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, canvas in
                draw(in: &context, canvas: canvas, time: t)
            }
        }
        .frame(width: size, height: size)
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, canvas: CGSize, time: Double) {
        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        // Headroom for halo + ripples. Widest draw is a full-amplitude ripple
        // at 1.45r, so 0.62 keeps it at ~0.45 of the frame — clear of the edge
        // the canvas would otherwise clip it against.
        let radius = min(canvas.width, canvas.height) * 0.5 * 0.62
        let (warm, cool) = state.palette
        let phase = reduceMotion ? 0 : time * state.churn

        // Breathing: a slow baseline swell, plus whatever the voice is doing.
        let breath = reduceMotion ? 0 : sin(time * 1.15) * 0.015
        let scale = 1 + breath + amplitude * 0.22
        let r = radius * scale

        drawHalo(&context, center: center, radius: r, warm: warm, cool: cool)
        if state.showsRipples { drawRipples(&context, center: center, radius: r, time: time, tint: warm) }
        drawBody(&context, center: center, radius: r, phase: phase, warm: warm, cool: cool)
        drawHighlight(&context, center: center, radius: r)
    }

    /// Ambient bloom. Grows with amplitude so a loud room visibly lights it up.
    private func drawHalo(_ context: inout GraphicsContext,
                          center: CGPoint, radius: CGFloat,
                          warm: Color, cool: Color) {
        let haloRadius = radius * (1.10 + amplitude * 0.24)
        var halo = context
        halo.addFilter(.blur(radius: radius * 0.13))
        halo.fill(
            Path(ellipseIn: CGRect(x: center.x - haloRadius, y: center.y - haloRadius,
                                   width: haloRadius * 2, height: haloRadius * 2)),
            with: .radialGradient(
                Gradient(colors: [warm.opacity(0.42 + amplitude * 0.30),
                                  cool.opacity(0.16),
                                  .clear]),
                center: center, startRadius: radius * 0.55, endRadius: haloRadius)
        )
    }

    /// Concentric rings pushing outward — only while audio is actually moving,
    /// so silence looks like silence.
    private func drawRipples(_ context: inout GraphicsContext,
                             center: CGPoint, radius: CGFloat,
                             time: Double, tint: Color) {
        guard !reduceMotion, amplitude > 0.06 else { return }
        for index in 0..<3 {
            // Each ring is offset a third of a cycle behind the last.
            let progress = ((time * 0.55) + Double(index) / 3).truncatingRemainder(dividingBy: 1)
            let ringRadius = radius * (1.02 + progress * (0.28 + amplitude * 0.15))
            let fade = (1 - progress) * amplitude * 0.55
            guard fade > 0.01 else { continue }
            context.stroke(
                Path(ellipseIn: CGRect(x: center.x - ringRadius, y: center.y - ringRadius,
                                       width: ringRadius * 2, height: ringRadius * 2)),
                with: .color(tint.opacity(fade)),
                lineWidth: max(0.75, radius * 0.035 * (1 - progress))
            )
        }
    }

    /// The sphere itself: a wobbling silhouette filled with a soft gradient.
    private func drawBody(_ context: inout GraphicsContext,
                          center: CGPoint, radius: CGFloat, phase: Double,
                          warm: Color, cool: Color) {
        let wobble = state.baseWobble + amplitude * 0.10
        let path = blob(center: center, radius: radius, wobble: wobble, phase: phase)
        context.fill(
            path,
            with: .radialGradient(
                Gradient(colors: [warm, warm.opacity(0.92), cool]),
                // Off-centre so the sphere reads as lit from the upper left.
                center: CGPoint(x: center.x - radius * 0.28, y: center.y - radius * 0.32),
                startRadius: 0, endRadius: radius * 1.5)
        )
        // A rim of the cool stop keeps the edge from going flat against dark
        // backgrounds.
        context.stroke(path, with: .color(cool.opacity(0.5)), lineWidth: max(0.5, radius * 0.02))
    }

    /// Specular dot. Small, high, and offset — the one cue that sells "sphere"
    /// rather than "circle".
    private func drawHighlight(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let highlightRadius = radius * 0.30
        let origin = CGPoint(x: center.x - radius * 0.34, y: center.y - radius * 0.40)
        var layer = context
        layer.addFilter(.blur(radius: radius * 0.14))
        layer.fill(
            Path(ellipseIn: CGRect(x: origin.x - highlightRadius, y: origin.y - highlightRadius,
                                   width: highlightRadius * 2, height: highlightRadius * 2)),
            with: .radialGradient(
                Gradient(colors: [.white.opacity(0.55), .white.opacity(0.05), .clear]),
                center: origin, startRadius: 0, endRadius: highlightRadius)
        )
    }

    /// A closed circle whose radius is perturbed by three harmonics. Three is
    /// enough to look organic; more just reads as noise.
    private func blob(center: CGPoint, radius: CGFloat, wobble: Double, phase: Double) -> Path {
        let steps = 72
        var path = Path()
        for step in 0...steps {
            let theta = Double(step) / Double(steps) * 2 * .pi
            let perturbation =
                sin(theta * 3 + phase * 1.7) * 0.55 +
                sin(theta * 5 - phase * 1.1) * 0.30 +
                sin(theta * 2 + phase * 0.6) * 0.15
            let r = radius * (1 + wobble * perturbation)
            let point = CGPoint(x: center.x + cos(theta) * r, y: center.y + sin(theta) * r)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
