import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// "Rewrite with Anu" — an action extension for selected text (Android parity
/// row 20; Android ADR-042). It shows AI Writing's six actions and a field for
/// the user's own instruction, previews the result, and hands it back to the
/// host with Replace (where the host accepts returned text) or puts it on the
/// pasteboard with Copy. It runs Apple's on-device model in this process when
/// available; otherwise it can hand the text to the Anu app through the App
/// Group. It never sends text to the cloud.
final class WritingActionViewController: UIViewController {
    private lazy var model = WritingActionModel(
        engine: ExtensionWriting.appleEngine(),
        engineNote: ExtensionWriting.unavailableReason,
        store: WritingHandoffStore(),
        fits: ExtensionWriting.fitsApple,
        finish: { [weak self] text in self?.finish(returning: text) })

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: WritingActionView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        loadSelectedText()
    }

    /// The selected text: the item's attributed text, else a plain-text attachment.
    private func loadSelectedText() {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        if let text = items.lazy.compactMap({ $0.attributedContentText?.string }).first(where: { !$0.isEmpty }) {
            model.load(text)
            return
        }
        let type = UTType.plainText.identifier
        guard let provider = items.lazy.flatMap({ $0.attachments ?? [] })
            .first(where: { $0.hasItemConformingToTypeIdentifier(type) }) else {
            model.load("")
            return
        }
        provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] value, _ in
            let text: String
            switch value {
            case let s as String: text = s
            case let a as NSAttributedString: text = a.string
            case let d as Data: text = String(data: d, encoding: .utf8) ?? ""
            case let u as URL: text = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
            default: text = ""
            }
            DispatchQueue.main.async { self?.model.load(text) }
        }
    }

    /// Replace returns the edited text to the host; nil just closes.
    private func finish(returning text: String?) {
        guard let text else {
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }
        let item = NSExtensionItem()
        item.attributedContentText = NSAttributedString(string: text)
        item.attachments = [NSItemProvider(item: text as NSString, typeIdentifier: UTType.plainText.identifier)]
        extensionContext?.completeRequest(returningItems: [item], completionHandler: nil)
    }
}
