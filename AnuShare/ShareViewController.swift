import UIKit
import UniformTypeIdentifiers

/// Share Sheet entry point. Takes the shared text or URL, drops it into the App
/// Group inbox, and completes — the official "do work and dismiss" pattern (no
/// `openURL` hack). The app drains the inbox the next time it becomes active and
/// runs the prompt through the normal agent pipeline.
///
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
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let provider = item.attachments?.first else {
            return complete()
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
