import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Cross-platform SwiftUI shims
//
// Anu ships the same SwiftUI views on iOS/iPadOS and macOS. A handful of
// modifiers and placements are iOS-only; these helpers paper over the
// difference in ONE place so the views read the same on every platform.

extension ToolbarItemPlacement {
    /// Leading toolbar slot — `.topBarLeading` on iOS, the macOS navigation slot
    /// otherwise (`.topBar*` placements don't exist on native macOS).
    static var anuLeading: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    /// Trailing toolbar slot — `.topBarTrailing` on iOS, `.primaryAction` on macOS.
    static var anuTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

extension Color {
    // The app uses a handful of UIColor-backed system colors that don't exist on
    // macOS. These map to the exact iOS colors on iOS, and to dark-mode-aware
    // approximations on macOS (AppKit has no `systemGrayN`).

    /// Subtle fill surface (iOS `.systemGray6`).
    static var anuFill6: Color {
        #if os(iOS)
        return Color(.systemGray6)
        #else
        return Color.primary.opacity(0.06)
        #endif
    }

    /// Slightly stronger fill (iOS `.systemGray5`).
    static var anuFill5: Color {
        #if os(iOS)
        return Color(.systemGray5)
        #else
        return Color.primary.opacity(0.10)
        #endif
    }

    /// Stronger fill / separators (iOS `.systemGray4`).
    static var anuFill4: Color {
        #if os(iOS)
        return Color(.systemGray4)
        #else
        return Color.primary.opacity(0.14)
        #endif
    }

    /// Primary surface (iOS `.systemBackground`).
    static var anuBackground: Color {
        #if os(iOS)
        return Color(.systemBackground)
        #else
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// Secondary grouped surface (iOS `.secondarySystemGroupedBackground`).
    static var anuGroupedBackgroundSecondary: Color {
        #if os(iOS)
        return Color(.secondarySystemGroupedBackground)
        #else
        return Color(nsColor: .controlBackgroundColor)
        #endif
    }
}

extension Image {
    /// Build an `Image` from raw image bytes using the platform image type
    /// (`UIImage` on iOS, `NSImage` on macOS). Fails if the data isn't an image.
    init?(platformImageData data: Data) {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        self.init(uiImage: image)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        self.init(nsImage: image)
        #else
        return nil
        #endif
    }
}

extension View {
    /// Disable autocorrection for identifier-like fields. Also disables
    /// autocapitalization on iOS (`.textInputAutocapitalization` is iOS-only).
    func anuNoAutocorrect() -> some View {
        #if os(iOS)
        return self.autocorrectionDisabled().textInputAutocapitalization(.never)
        #else
        return self.autocorrectionDisabled()
        #endif
    }

    /// Like `anuNoAutocorrect()`, plus a URL keyboard on iOS (`.keyboardType` is
    /// iOS-only; macOS keyboards aren't typed).
    func anuURLField() -> some View {
        #if os(iOS)
        return self.autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
        #else
        return self.autocorrectionDisabled()
        #endif
    }
}

extension View {
    /// Presents voice mode edge-to-edge on iOS; macOS has no
    /// `fullScreenCover`, so it gets a sheet sized to feel similar.
    @ViewBuilder
    func voiceModeCover<Content: View>(isPresented: Binding<Bool>,
                                       @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented) {
            content().frame(minWidth: 420, minHeight: 560)
        }
        #endif
    }
}
