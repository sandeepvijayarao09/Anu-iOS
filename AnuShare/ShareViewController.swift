import UIKit
import UniformTypeIdentifiers

/// Share Sheet entry point. Takes the shared text or URL, drops it into the App
/// Group inbox, and completes — the official "do work and dismiss" pattern (no
/// `openURL` hack). The app drains the inbox the next time it becomes active and
/// runs the prompt through the normal agent pipeline.
///
/// Photos (up to four) and a PDF are handed over through `SharedMedia` and
/// wait in the chat's composer, as Android's shares open Talk with them
/// attached (ADR-094, ADR-095). They're never sent anywhere from here.
/// A shared recording (Android ADR-078) is decoded here to mono 16 kHz PCM,
/// sealed with `SecureFile` under the App Group key, and waits above Anu's
/// composer as a voice note the next time Anu opens. It's written down on the
/// device when the user sends it; the audio never leaves the phone.
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        handleShare()
    }

    private func handleShare() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        guard let provider = providers.first else {
            return complete()
        }

        let pdfs = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) }
        let images = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        if !pdfs.isEmpty || !images.isEmpty {
            return handOver(pdf: pdfs.first, images: Array(images.prefix(4)))
        }

        let textType = UTType.plainText.identifier
        let urlType = UTType.url.identifier
        let audioType = UTType.audio.identifier

        if provider.hasItemConformingToTypeIdentifier(audioType) {
            provider.loadFileRepresentation(forTypeIdentifier: audioType) { [weak self] url, _ in
                // The file only exists inside this callback: decode it now.
                if let url {
                    let note = SharedAudioDecoder.decode(url)
                    try? SharedVoiceNoteDrop().drop(note)
                }
                self?.complete()
            }
        } else if provider.hasItemConformingToTypeIdentifier(textType) {
            provider.loadItem(forTypeIdentifier: textType, options: nil) { [weak self] value, _ in
                self?.enqueue((value as? String))
            }
        } else if provider.hasItemConformingToTypeIdentifier(urlType) {
            provider.loadItem(forTypeIdentifier: urlType, options: nil) { [weak self] value, _ in
                self?.enqueue((value as? URL)?.absoluteString)
            }
        } else {
            complete()
        }
    }

    /// Writes the shared PDF and photos for the app, then queues them.
    private func handOver(pdf: NSItemProvider?, images: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var names: [String] = []
        func load(_ provider: NSItemProvider, type: UTType, fallbackName: String) {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                defer { group.leave() }
                guard let data else { return }
                let fileName = provider.suggestedName.map { name in
                    type == .pdf && !name.lowercased().hasSuffix(".pdf") ? name + ".pdf" : name
                } ?? fallbackName
                if let name = SharedMedia.put(data, fileName: fileName) {
                    lock.lock(); names.append(name); lock.unlock()
                }
            }
        }
        if let pdf { load(pdf, type: .pdf, fallbackName: "Shared.pdf") }
        for image in images { load(image, type: .image, fallbackName: "Photo") }
        group.notify(queue: .main) { [weak self] in
            InboxStore().enqueue(attachments: names)
            self?.complete()
        }
    }

    private func enqueue(_ shared: String?) {
        if let shared, !shared.isEmpty {
            InboxStore().enqueue("I shared this with you — take a look and help me with it:\n\n\(shared)")
        }
        complete()
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
