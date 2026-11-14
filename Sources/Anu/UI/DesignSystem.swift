import SwiftUI

// MARK: - Design system
//
// Anu's visual language had drifted: 17 distinct spacing values (including 1, 3,
// 5, 7, 14, 18), five corner radii on sibling surfaces, and the accent colour
// applied to 20 places including every utility icon — so nothing on screen read
// as primary. None of that is visible as a "bug"; it registers as a low-grade
// unease the eye can't name.
//
// These tokens make the correct choice the easy one. Three rules:
//
//   1. Every gap is a `Space` step. No literals.
//   2. Every surface uses a `Radius` step, chosen by the surface's size.
//   3. The accent marks the ONE primary action in a view. Everything else is
//      neutral. Destructive is the only other colour that carries meaning.

/// 4pt spacing scale. `hair` and `tight` are the deliberate half-steps for
/// text stacks, where a full 4pt gap reads as a paragraph break.
enum Space {
    /// 2 — between a label and the value it describes.
    static let hair: CGFloat = 2
    /// 4 — between an icon and its label.
    static let xs: CGFloat = 4
    /// 6 — within a tight text stack.
    static let tight: CGFloat = 6
    /// 8 — between related controls.
    static let snug: CGFloat = 8
    /// 12 — default gap inside a card.
    static let base: CGFloat = 12
    /// 16 — screen margin, gap between cards.
    static let comfy: CGFloat = 16
    /// 24 — between distinct groups.
    static let loose: CGFloat = 24
    /// 32 — between major sections.
    static let section: CGFloat = 32
    /// 48 — above a focal point, to give it room to be the focal point.
    static let stage: CGFloat = 48
}

/// Corner radii, picked by surface size so curvature stays proportional.
/// Mixing 6 / 8 / 12 / 14 / 18 on siblings is what made the old surfaces look
/// accidental.
enum Radius {
    /// 8 — chips, badges, small inline fills.
    static let small: CGFloat = 8
    /// 12 — cards, rows, sheets' inner surfaces.
    static let medium: CGFloat = 12
    /// 18 — message bubbles and other large soft surfaces.
    static let large: CGFloat = 18
}

extension Color {

    /// The one accent. Reserved for the primary action in a view and for the
    /// user's own message bubble — never for utility icons.
    static let anuAccent = Color.accentColor

    /// Utility and secondary icons. Neutral on purpose: an icon row where
    /// everything is accent-coloured has no hierarchy at all.
    static var anuIcon: Color { .secondary }

    /// Destructive intent. The only colour besides the accent that means
    /// something on its own.
    static let anuDestructive = Color.red

    /// Near-black body text. Pure black on white is harsher than it needs to
    /// be; this reads softer while staying well above WCAG AA.
    static var anuInk: Color {
        #if os(iOS)
        return Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.96, alpha: 1)
                : UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)
        })
        #else
        return .primary
        #endif
    }

    /// Hairline separator. Lower contrast than `.separator` so a border can
    /// define an edge without drawing attention to itself.
    static var anuHairline: Color { Color.primary.opacity(0.08) }
}

extension View {

    /// A resting card surface: subtle fill, hairline edge, no shadow. Elevation
    /// is reserved for things that genuinely float (sheets, menus), so resting
    /// content stays calm.
    func anuCard(radius: CGFloat = Radius.medium, padding: CGFloat = Space.base) -> some View {
        self
            .padding(padding)
            .background(Color.anuFill6, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.anuHairline, lineWidth: 1)
            )
    }
}
