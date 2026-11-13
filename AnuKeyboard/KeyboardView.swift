import SwiftUI
import UIKit

/// The keyboard: the AI strip (or its preview) above the keys.
struct KeyboardView: View {
    static let stripHeight: CGFloat = 46
    static let rowHeight: CGFloat = 50
    static let height: CGFloat = stripHeight + rowHeight * 4 + 16

    @ObservedObject var state: KeyboardState
    @ObservedObject private var assist: KeyboardAssist

    init(state: KeyboardState) {
        self.state = state
        self._assist = ObservedObject(wrappedValue: state.assist)
    }

    var body: some View {
        VStack(spacing: 0) {
            strip
                .frame(minHeight: Self.stripHeight)
            keys
                .padding(.horizontal, 3)
                .padding(.bottom, 4)
        }
        .background(Color(uiColor: .systemGray5).opacity(0.001))
    }

    // MARK: Strip

    @ViewBuilder private var strip: some View {
        if let note = state.stripNote {
            HStack(spacing: 6) {
                Image(systemName: state.policy.isPrivate ? "lock.fill" : "info.circle")
                Text(note).lineLimit(2).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
        } else if state.askOpen {
            askField
        } else {
            switch assist.state {
            case .idle:
                pills
            case .working(let action):
                status(action.working, busy: true) { state.discard() }
            case .waiting(let action):
                HStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                    Text("\(action.label) is waiting for Anu. Open the Anu app, then come back.")
                        .lineLimit(2).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    Button("Get result") { state.checkHandoff() }.buttonStyle(.bordered).controlSize(.small)
                    Button { state.discard() } label: { Image(systemName: "xmark") }
                }
                .font(.footnote)
                .padding(.horizontal, 10)
            case .ready(let ready):
                preview(ready)
            case .note(let text):
                status(text, busy: false) { state.discard() }
            }
        }
    }

    private var pills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                pill("Ask Anu", systemImage: "sparkles") { state.openAsk() }
                ForEach(state.actions, id: \.self) { action in
                    pill(action.label) { state.run(action) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func pill(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
        }
        .buttonStyle(.plain)
    }

    private var askField: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
            Text(state.askText.isEmpty ? "Ask Anu to write or change…" : state.askText)
                .foregroundStyle(state.askText.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            Button { state.closeAsk() } label: { Image(systemName: "xmark.circle.fill") }
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemBackground)))
        .padding(.horizontal, 8)
    }

    private func status(_ text: String, busy: Bool, cancel: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            Text(text).font(.footnote).lineLimit(2).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Button(action: cancel) { Image(systemName: "xmark") }
        }
        .padding(.horizontal, 12)
    }

    private func preview(_ ready: AssistReady) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("\(ready.action.label) · On this device · \(ready.engine)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            if ready.choices.isEmpty {
                HStack(spacing: 8) {
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(ready.result).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 64)
                    VStack(spacing: 4) {
                        Button(ready.acceptLabel) { state.accept() }.buttonStyle(.borderedProminent).controlSize(.small)
                        Button("Discard") { state.discard() }.controlSize(.small)
                    }
                }
            } else {
                HStack(spacing: 4) {
                    ForEach(ready.choices, id: \.self) { emoji in
                        Button(emoji) { state.accept(choice: emoji) }
                            .font(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    Spacer(minLength: 0)
                    Button { state.discard() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: Keys

    private var rows: [[KeyboardKey]] {
        if KeyboardLayout.usesPad(state.policy.layout) && !state.askOpen {
            return KeyboardLayout.pad(state.policy.layout, globe: state.showsGlobe)
        }
        return KeyboardLayout.rows(state.page, shift: state.shift, globe: state.showsGlobe)
    }

    private var keys: some View {
        VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GeometryReader { geo in
                    let total = row.reduce(0) { $0 + $1.weight }
                    let unit = (geo.size.width - CGFloat(row.count - 1) * 5) / CGFloat(total)
                    HStack(spacing: 5) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, key in
                            KeyCap(key: key, state: state)
                                .frame(width: max(0, unit * CGFloat(key.weight)))
                        }
                    }
                }
                .frame(height: Self.rowHeight - 6)
            }
        }
        .padding(.top, 4)
    }
}

/// One key. Fires on touch-up; delete repeats while held.
private struct KeyCap: View {
    let key: KeyboardKey
    @ObservedObject var state: KeyboardState
    @State private var pressed = false
    @State private var repeatTimer: Timer?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(fill)
                    .shadow(color: .black.opacity(isGap ? 0 : 0.25), radius: 0, x: 0, y: 1)
            )
            .contentShape(Rectangle())
            .gesture(isGap ? nil : press)
            .accessibilityAddTraits(.isKeyboardKey)
            .accessibilityLabel(accessibilityName)
    }

    private var isGap: Bool { if case .gap = key { return true } else { return false } }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !pressed else { return }
                pressed = true
                if case .backspace = key {
                    state.tap(key)
                    repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
                        Task { @MainActor in
                            repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                                Task { @MainActor in state.tap(key) }
                            }
                        }
                    }
                }
            }
            .onEnded { _ in
                pressed = false
                repeatTimer?.invalidate()
                repeatTimer = nil
                if case .backspace = key { return }
                state.tap(key)
            }
    }

    private var fill: Color {
        if isGap { return .clear }
        let special: Bool
        switch key {
        case .text, .space: special = false
        case .enter: return state.enterIsAction ? .accentColor : Color(uiColor: .systemGray3)
        default: special = true
        }
        if pressed { return Color(uiColor: .systemGray2) }
        return special ? Color(uiColor: .systemGray3) : Color(uiColor: .systemBackground)
    }

    @ViewBuilder private var content: some View {
        switch key {
        case .text(let t, _):
            Text(t).font(.system(size: 22))
        case .shift:
            Image(systemName: state.shift == .locked ? "capslock.fill" : (state.shift == .once ? "shift.fill" : "shift"))
        case .backspace:
            Image(systemName: "delete.left")
        case .page(_, let label, _):
            Text(label).font(.system(size: 15))
        case .globe:
            Image(systemName: "globe")
        case .space:
            Text(state.askOpen ? "space · Ask Anu" : "space").font(.system(size: 15)).foregroundStyle(.secondary)
        case .enter:
            Text(state.enterLabel).font(.system(size: 15))
                .foregroundStyle(state.enterIsAction ? Color.white : Color.primary)
        case .gap:
            Color.clear
        }
    }

    private var accessibilityName: String {
        switch key {
        case .text(let t, _): return t
        case .shift: return "shift"
        case .backspace: return "delete"
        case .page(_, let label, _): return label
        case .globe: return "next keyboard"
        case .space: return "space"
        case .enter: return state.enterLabel
        case .gap: return ""
        }
    }
}
