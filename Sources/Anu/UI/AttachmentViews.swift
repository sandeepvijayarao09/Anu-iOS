import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Shared into Anu

/// Photos and PDFs shared from another app, waiting for the composer. The
/// orchestrator fills it when it drains the inbox; the chat takes them.
@MainActor
final class SharedAttachmentInbox: ObservableObject {
    static let shared = SharedAttachmentInbox()

    struct Item: Sendable {
        let data: Data
        let name: String
        let isPDF: Bool
        /// Handed over as a screen: masked like one whatever it looks like.
        var isScreen = false
    }

    @Published private(set) var items: [Item] = []

    /// Reads each handed-off file once (and deletes it).
    func receive(_ names: [String]) {
        items += names.compactMap { name in
            SharedMedia.take(name).map { Item(data: $0, name: SharedMedia.displayName(name), isPDF: SharedMedia.isPDF(name),
                                              isScreen: SharedMedia.isScreenshot(name)) }
        }
    }

    func takeAll() -> [Item] {
        defer { items = [] }
        return items
    }
}

// MARK: - Composer state

/// What waits above the composer: up to four photos (picker, camera, share)
/// and one PDF. Every photo is readied before it's shown — a screen has its
/// secrets blacked out, and each is cut to 1,024 pixels — so the thumbnail is
/// exactly what the model will see.
@MainActor
final class AttachmentComposer: ObservableObject {
    @Published private(set) var attachments = MessageAttachments()
    /// "Anu can look at up to 4 photos at once.", or a PDF that couldn't be read.
    @Published var notice: String?
    @Published private(set) var preparing = 0
    @Published var pickerItems: [PhotosPickerItem] = []
    /// Chosen with "Ask About My Screen" (the Screenshots picker): masked as screens.
    @Published var screenPickerItems: [PhotosPickerItem] = []
    @Published var showPDFPicker = false

    var isEmpty: Bool { attachments.isEmpty }
    var photosLeft: Int { max(0, attachments.photosLeft - preparing) }

    /// Readies and adds photos; past four, the rest are left out with a notice.
    func addPhotos(_ raw: [Data], asScreens: Bool = false) {
        let fits = Array(raw.prefix(photosLeft))
        notice = fits.count < raw.count ? MessageAttachments.tooMany : nil
        guard !fits.isEmpty else { return }
        preparing += fits.count
        Task {
            let prepared = await Task.detached(priority: .userInitiated) {
                fits.compactMap { PhotoPreparation.prepare($0, forceScreen: asScreens) }
            }.value
            preparing -= fits.count
            let left = attachments.add(photos: prepared.map(\.data))
            attachments.knownCodes += prepared.flatMap(\.codes)
            if left > 0 { notice = MessageAttachments.tooMany }
            if prepared.count < fits.count { notice = "Anu couldn't open one of those pictures." }
        }
    }

    /// Loads the photos chosen in the system picker.
    func loadPicked() {
        let items = pickerItems
        pickerItems = []
        load(items, asScreens: false)
    }

    /// Loads the screenshot chosen with "Ask About My Screen".
    func loadPickedScreens() {
        let items = screenPickerItems
        screenPickerItems = []
        load(items, asScreens: true)
    }

    private func load(_ items: [PhotosPickerItem], asScreens: Bool) {
        guard !items.isEmpty else { return }
        Task {
            var raw: [Data] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) { raw.append(data) }
            }
            addPhotos(raw, asScreens: asScreens)
        }
    }

    /// Reads a picked PDF into memory (the file itself is never copied).
    func importPDF(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            notice = "Anu couldn't open that PDF."
            return
        }
        addPDF(data, name: url.lastPathComponent)
    }

    func addPDF(_ data: Data, name: String) {
        #if canImport(PDFKit)
        notice = PDFAttachment.attach(data, name: name, to: &attachments)?.message
        #else
        notice = "PDFs can't be read on this device."
        #endif
    }

    func takeShared(_ items: [SharedAttachmentInbox.Item]) {
        for item in items where item.isPDF { addPDF(item.data, name: item.name) }
        let photos = items.filter { !$0.isPDF && !$0.isScreen }.map(\.data)
        if !photos.isEmpty { addPhotos(photos) }
        let screens = items.filter { !$0.isPDF && $0.isScreen }.map(\.data)
        if !screens.isEmpty { addPhotos(screens, asScreens: true) }
    }

    func removePhoto(at index: Int) {
        attachments.removePhoto(at: index)
        notice = nil
    }

    func removeDocument() {
        attachments.removeDocument()
        notice = nil
    }

    /// Hands everything to the message being sent and clears the tray.
    func take() -> MessageAttachments {
        defer { attachments = MessageAttachments(); notice = nil }
        return attachments
    }
}

// MARK: - Tray above the composer

/// Thumbnails (each with its own remove badge) and the PDF pill.
struct AttachmentTray: View {
    @ObservedObject var composer: AttachmentComposer

    var body: some View {
        if !composer.isEmpty || composer.preparing > 0 || composer.notice != nil {
            VStack(alignment: .leading, spacing: Space.tight) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.snug) {
                        if let document = composer.attachments.document {
                            DocumentPill(document: document, onRemove: composer.removeDocument)
                        }
                        let pages = composer.attachments.documentPictures
                        ForEach(Array(composer.attachments.photos.enumerated()), id: \.offset) { index, data in
                            if !pages.contains(data) {
                                thumbnail(data, index: index)
                            }
                        }
                        if composer.preparing > 0 { ProgressView().frame(width: 64, height: 64) }
                    }
                }
                if let notice = composer.notice {
                    Text(notice)
                        .font(.anuMeta)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("attachmentNotice")
                }
            }
            .padding(.horizontal, Space.comfy)
            .padding(.vertical, Space.tight)
            .background(Color.anuFill6)
        }
    }

    private func thumbnail(_ data: Data, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            if let image = Image(platformImageData: data) {
                image.resizable().scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small))
            }
            Button { composer.removePhoto(at: index) } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(2)
            .accessibilityLabel("Remove photo \(index + 1)")
        }
        .accessibilityIdentifier("attachedPhoto")
    }
}

/// "Lease.pdf · 12 pages", with Remove when it's still in the composer.
struct DocumentPill: View {
    let document: AttachedDocument
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: Space.tight) {
            Image(systemName: "doc.richtext")
            Text(document.label)
                .font(.anuLabel)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(document.name)")
            }
        }
        .padding(.horizontal, Space.base)
        .padding(.vertical, Space.snug)
        .background(Color.anuFill6, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.anuHairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("documentPill")
    }
}

// MARK: - In the user's turn

/// A user turn's photos and PDF, above its words: one photo as it is, several
/// as a two-column grid of square crops.
struct UserAttachmentsView: View {
    let message: AgentMessage

    var body: some View {
        VStack(alignment: .trailing, spacing: Space.xs) {
            if let document = message.document { DocumentPill(document: document) }
            let photos = message.photos ?? []
            if photos.count == 1, let image = Image(platformImageData: photos[0]) {
                image.resizable().scaledToFill()
                    .frame(maxWidth: 180, maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.medium))
                    .accessibilityLabel("Attached photo")
            } else if photos.count > 1 {
                LazyVGrid(columns: [GridItem(.fixed(96), spacing: 4), GridItem(.fixed(96), spacing: 4)], spacing: 4) {
                    ForEach(Array(photos.enumerated()), id: \.offset) { index, data in
                        if let image = Image(platformImageData: data) {
                            image.resizable().scaledToFill()
                                .frame(width: 96, height: 96)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                                .accessibilityLabel("Attached photo \(index + 1) of \(photos.count)")
                        }
                    }
                }
                .frame(width: 196)
                .accessibilityIdentifier("photoGrid")
            }
        }
    }
}
