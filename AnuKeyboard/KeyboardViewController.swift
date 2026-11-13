import UIKit
import SwiftUI

/// Anu's keyboard (Android parity row 21; Android ADR-109, ADR-122, ADR-149).
///
/// Typing works everywhere iOS allows a custom keyboard, with or without
/// "Allow Full Access": keys go straight to the field with `insertText`, with
/// no dictionary, no suggestions and no history, so nothing typed is kept.
///
/// The AI strip reads the field only when an action is tapped, never in a
/// private field (password, one-time code, card), and never sends text off the
/// device: it uses Apple's on-device model in this process when available, or
/// — only with Full Access, which gives the keyboard the App Group — hands the
/// text to the Anu app's on-device model. A result is a preview until the user
/// taps Replace or Insert.
final class KeyboardViewController: UIInputViewController {
    private lazy var state = KeyboardState(controller: self)
    private var heightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: KeyboardView(state: state))
        host.view.backgroundColor = .clear
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
        let height = view.heightAnchor.constraint(equalToConstant: KeyboardView.height)
        height.priority = .defaultHigh
        height.isActive = true
        heightConstraint = height
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        state.refreshField()
        state.assist.checkHandoff()
        reportStatus()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Nothing kept: the preview and any instruction go with the keyboard.
        state.keyboardHidden()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        state.refreshField()
    }

    // MARK: - What the state needs from UIKit

    var traits: FieldTraits {
        let proxy = textDocumentProxy
        return FieldTraits(
            keyboardType: proxy.keyboardType?.rawValue ?? FieldTraits.KeyboardType.default,
            returnKeyType: proxy.returnKeyType?.rawValue ?? FieldTraits.ReturnKey.default,
            autocapitalization: proxy.autocapitalizationType?.rawValue ?? FieldTraits.Autocapitalization.sentences,
            isSecureTextEntry: proxy.isSecureTextEntry ?? false,
            textContentType: proxy.textContentType??.rawValue)
    }

    /// The field around the cursor. Call only on an AI tap, never in a private field.
    func readField() -> FieldText {
        FieldText(before: textDocumentProxy.documentContextBeforeInput, selected: textDocumentProxy.selectedText)
    }

    /// The text before the cursor, for capitals. Never read in a private field.
    func contextBefore() -> String? { textDocumentProxy.documentContextBeforeInput }

    func insert(_ text: String) { textDocumentProxy.insertText(text) }
    func deleteBackward() { textDocumentProxy.deleteBackward() }

    func apply(_ edit: KeyboardEdit) {
        for _ in 0..<edit.deleteBefore { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(edit.insert)
    }

    func nextKeyboard() { advanceToNextInputMode() }

    var showsGlobe: Bool { needsInputModeSwitchKey }

    /// Settings → Keyboard shows this. It holds no text; without Full Access
    /// the keyboard has no App Group, so nothing is written.
    private func reportStatus() {
        guard hasFullAccess else { return }
        KeyboardStatusStore().save(KeyboardStatus(lastSeen: Date(), hasFullAccess: true,
                                                  appleModelAvailable: ExtensionWriting.appleEngine() != nil))
    }
}

/// The keyboard's live state: page, shift, the Ask field and the AI strip.
@MainActor
final class KeyboardState: ObservableObject {
    @Published private(set) var policy = FieldPolicy.of(FieldTraits())
    @Published var page: KeyboardPage = .letters
    @Published var shift: ShiftState = .off
    @Published private(set) var askOpen = false
    @Published private(set) var askText = ""
    @Published private(set) var showsGlobe = true

    let assist: KeyboardAssist
    let hasFullAccess: Bool
    private unowned let controller: KeyboardViewController
    private var lastShiftTap = Date.distantPast
    private var lastTraits: FieldTraits?

    init(controller: KeyboardViewController) {
        self.controller = controller
        self.hasFullAccess = controller.hasFullAccess
        self.assist = KeyboardAssist(engine: { ExtensionWriting.appleEngine() },
                                     handoff: controller.hasFullAccess ? WritingHandoffStore() : nil)
    }

    /// What the strip needs to say when it can't help in this field.
    var stripNote: String? {
        if let note = policy.stripNote { return note }
        if !assist.canAssist { return KeyboardAssistLogic.noEngineNote }
        return nil
    }

    var actions: [KeyboardAction] { KeyboardAction.strip(chat: policy.chat) }

    func refreshField() {
        let traits = controller.traits
        if traits != lastTraits {
            lastTraits = traits
            policy = FieldPolicy.of(traits)
            page = KeyboardLayout.startPage(policy.layout)
            closeAsk()
            if policy.isPrivate || !policy.ai { assist.hidden() }
        }
        showsGlobe = controller.showsGlobe
        autoShift()
    }

    func keyboardHidden() {
        closeAsk()
        assist.hidden()
        lastTraits = nil
    }

    private func autoShift() {
        guard page == .letters, !askOpen else { return }
        // A private field is never read, not even for capitals.
        let before = policy.isPrivate ? nil : controller.contextBefore()
        shift = ShiftRules.auto(shift, capsNow: policy.wantsCapital(before: before))
    }

    // MARK: Keys

    func tap(_ key: KeyboardKey) {
        switch key {
        case .text(let t, _):
            let text = shift == .off ? t : t.uppercased()
            if askOpen { askText = KeyboardText.askEdit(askText, typed: text) } else { controller.insert(text) }
            shift = ShiftRules.afterText(shift)
            if !askOpen { autoShift() }
        case .shift:
            let now = Date()
            shift = ShiftRules.tap(shift, sinceLastTap: now.timeIntervalSince(lastShiftTap))
            lastShiftTap = now
        case .backspace:
            if askOpen { askText = KeyboardText.askEdit(askText, typed: nil) } else { controller.deleteBackward(); autoShift() }
        case .page(let to, _, _):
            page = to
            if to == .letters { autoShift() }
        case .globe:
            controller.nextKeyboard()
        case .space:
            if askOpen { askText = KeyboardText.askEdit(askText, typed: " ") } else { controller.insert(" "); autoShift() }
        case .enter:
            if askOpen { runAsk() } else { controller.insert("\n"); autoShift() }
        case .gap:
            break
        }
    }

    var enterLabel: String { askOpen ? "go" : policy.enter.label }
    var enterIsAction: Bool { askOpen || policy.enter.isAction }

    // MARK: AI strip

    func openAsk() {
        guard policy.ai else { return }
        askOpen = true
        askText = ""
        page = .letters
        shift = .once
    }

    func closeAsk() {
        askOpen = false
        askText = ""
    }

    func runAsk() {
        let instruction = askText
        closeAsk()
        run(.ask, ask: instruction)
    }

    func run(_ action: KeyboardAction, ask: String? = nil) {
        guard policy.ai else { return }
        // Read on the tap, once.
        assist.run(action, field: controller.readField(), ask: ask)
    }

    func accept(choice: String? = nil) {
        guard policy.ai, let edit = assist.accept(now: controller.readField(), choice: choice) else { return }
        controller.apply(edit)
    }

    func discard() { assist.clear() }
    func checkHandoff() { assist.checkHandoff() }
}
