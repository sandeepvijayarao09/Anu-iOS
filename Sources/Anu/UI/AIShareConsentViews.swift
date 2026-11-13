import SwiftUI

// MARK: - Consent sheet (parity A9)

/// The one-time question before Anu sends anything to a third-party AI. It
/// names the provider, says exactly what is sent, and waits: nothing leaves
/// until "Agree". "Not now" and swiping away both mean no.
struct AIShareConsentSheet: View {
    let provider: AIShareProvider
    let onAnswer: (Bool) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.comfy) {
                    Text(provider.operatorLine)
                        .font(.anuBody)
                        .foregroundStyle(Color.anuInk)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: Space.snug) {
                        Text("What is sent").font(.anuLabelStrong)
                        ForEach(AIShareProvider.whatIsSent, id: \.self) { line in
                            Label(line, systemImage: "checkmark.circle")
                                .font(.anuSecondary)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("Nothing is sent unless you agree. You can withdraw this any time in Settings → Privacy.")
                        .font(.anuLabel)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Space.comfy)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(provider.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: Space.snug) {
                    Button { onAnswer(true) } label: {
                        Text("Agree and send").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("consentAgreeButton")
                    Button { onAnswer(false) } label: {
                        Text("Not now").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("consentDeclineButton")
                }
                .controlSize(.large)
                .padding(Space.comfy)
                .background(.background)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.background)
        .accessibilityIdentifier("aiShareConsentSheet")
    }
}

/// Attaches the consent sheet; used once, at the app's root.
private struct AIShareConsentPresenter: ViewModifier {
    @ObservedObject private var center = AIShareConsentCenter.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { center.pending }, set: { if $0 == nil { center.answer(false) } })) { request in
                AIShareConsentSheet(provider: request.provider) { center.answer($0) }
            }
            .onAppear { center.attachPresenter() }
            .onDisappear { center.detachPresenter() }
    }
}

extension View {
    func aiShareConsentSheet() -> some View { modifier(AIShareConsentPresenter()) }
}

// MARK: - Settings → Privacy

/// Who Anu may share with, and a way to take it back.
struct AIShareConsentSection: View {
    @State private var records: [AIShareProvider: AIShareConsentRecord] = [:]
    private let store = AIShareConsentStore.shared

    var body: some View {
        Section {
            ForEach(AIShareProvider.allCases) { provider in
                HStack(spacing: Space.base) {
                    VStack(alignment: .leading, spacing: Space.hair) {
                        Text(provider.displayName.prefix(1).uppercased() + provider.displayName.dropFirst())
                            .font(.anuBody)
                        Text(status(provider))
                            .font(.anuLabel)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if records[provider] != nil {
                        Button("Withdraw", role: .destructive) {
                            store.revoke(provider)
                            reload()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("withdrawConsent_\(provider.rawValue)")
                    }
                }
            }
        } header: {
            Text("Sharing with other AI")
        } footer: {
            Text("Anu asks before it first sends anything to Google Gemini or your private compute server. Withdraw, and nothing more is sent until you agree again.")
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: AIShareConsentStore.didChange)) { _ in reload() }
    }

    private func status(_ provider: AIShareProvider) -> String {
        guard let record = records[provider] else { return "Not agreed · nothing is sent" }
        let date = DateFormatter.localizedString(from: record.acceptedAt, dateStyle: .medium, timeStyle: .none)
        return "Agreed on \(date)"
    }

    private func reload() {
        var map: [AIShareProvider: AIShareConsentRecord] = [:]
        for provider in AIShareProvider.allCases {
            if store.isGranted(provider), let record = store.record(for: provider) { map[provider] = record }
        }
        records = map
    }
}
