import SwiftUI
#if canImport(ImagePlayground)
import ImagePlayground
#endif

/// Presents Apple's Image Playground sheet (iOS 18.1+) for manual image
/// creation, seeded with `concept`. The completed image's data is handed back
/// via `onImage`. Compiles to a no-op passthrough where Image Playground is
/// unavailable, so the call site stays clean.
struct ImagePlaygroundPresenter: ViewModifier {
    @Binding var isPresented: Bool
    var concept: String
    var onImage: (Data) -> Void

    func body(content: Content) -> some View {
        #if canImport(ImagePlayground)
        if #available(iOS 18.1, *) {
            content.imagePlaygroundSheet(isPresented: $isPresented, concept: concept) { url in
                if let data = try? Data(contentsOf: url) { onImage(data) }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    /// Attaches the Image Playground sheet. `concept` seeds the prompt.
    func imageCreationSheet(isPresented: Binding<Bool>,
                            concept: String,
                            onImage: @escaping (Data) -> Void) -> some View {
        modifier(ImagePlaygroundPresenter(isPresented: isPresented, concept: concept, onImage: onImage))
    }
}

/// Whether manual image creation (Image Playground sheet) is offered on this
/// build/OS. The agent's `generate_image` tool has its own runtime check.
enum ImageCreation {
    static var isAvailable: Bool {
        #if canImport(ImagePlayground)
        if #available(iOS 18.1, *) { return true }
        #endif
        return false
    }
}
