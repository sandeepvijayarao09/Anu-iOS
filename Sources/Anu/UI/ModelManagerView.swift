import SwiftUI
import UniformTypeIdentifiers

/// Model Manager: see every brain the app can run and pick the active one:
/// Apple's on-device model (iOS/macOS 27, Apple Intelligence devices), or
/// Gemma 4 E2B / E4B on LiteRT-LM, bundled or fetched from the Google AI Edge
/// Gallery allowlist, or Automatic (Apple when available, else Gemma).
/// Selecting a ready model swaps it in place via
/// `AgentOrchestrator.switchActiveModel()` (no relaunch).
struct ModelManagerView: View {
    @ObservedObject private var manager = ModelManager.shared
    @ObservedObject private var orchestrator = AgentOrchestrator.shared
    @ObservedObject private var downloads = ModelDownloadManager.shared
    @State private var pickingModelFile = false
    @State private var installNote: String?
    @State private var installing = false

    var body: some View {
        List {
            statusSection
            ModelSpeedSection()
            section("Recommended", kinds: [.automatic],
                    footer: "Automatic uses Apple's on-device model when this device has it, and Gemma 4 otherwise.")
            section("Apple", kinds: [.appleOnDevice])
            privateCloudSection
            section("On this device", kinds: [.liteRT])
            // Only offer downloads where there's an engine to run them.
            #if canImport(LiteRTLM)
            downloadableSection
            if showTokenField { tokenSection }
            #endif
        }
        .navigationTitle("Model")
        .fileImporter(isPresented: $pickingModelFile, allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result else { return }
            installing = true
            installNote = nil
            Task {
                do {
                    let model = try await downloads.installFromFile(url)
                    installNote = "Installed \(model.name). Pick it above to use it."
                } catch {
                    installNote = (error as? ModelFileInstaller.Problem)?.errorDescription ?? error.localizedDescription
                }
                installing = false
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("modelManagerView")
    }

    /// Live connection status of the active brain — the info that used to be
    /// posted to the chat as load "disclaimers" now lives here.
    @ViewBuilder
    private var statusSection: some View {
        Section {
            HStack(spacing: Space.base) {
                statusIcon
                    .font(.anuHeading)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text(orchestrator.model.modelName)
                        .font(.anuBody.weight(.medium))
                    Text(orchestrator.modelLoadState.summary)
                        .font(.anuLabel)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("modelStatusSummary")
                }
                Spacer(minLength: 0)
            }
            if case .failed(let reason) = orchestrator.modelLoadState {
                Text(reason)
                    .font(.anuLabel)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Model status")
        } footer: {
            #if targetEnvironment(simulator)
            Text("The Simulator runs the model on CPU only (no Neural Engine), so replies are much slower here than on a real iPhone. For quick chats, turn on Fast mode in Settings → Performance.")
            #endif
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch orchestrator.modelLoadState {
        case .loading:
            ProgressView()
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func section(_ title: String, kinds: Set<ModelBackendKind>, footer: String? = nil) -> some View {
        let rows = manager.options.filter { kinds.contains($0.option.kind) }
        Section {
            ForEach(rows, id: \.option.id) { entry in
                ModelRow(
                    option: entry.option,
                    availability: entry.availability,
                    isSelected: entry.option.id == manager.selectedID
                ) {
                    manager.select(entry.option.id)
                    Task { await AgentOrchestrator.shared.switchActiveModel() }
                }
            }
        } header: {
            Text(title)
        } footer: {
            if let footer { Text(footer) }
        }
    }

    // MARK: - Apple Private Cloud Compute (parity A1)

    /// Whether big tasks can go to Apple's Private Cloud Compute, and if not, why.
    @ViewBuilder
    private var privateCloudSection: some View {
        let status = AppleModels.status(of: .privateCloud)
        Section {
            HStack(spacing: Space.base) {
                Image(systemName: "lock.icloud")
                    .foregroundStyle(status.isUsable ? Color.green : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text(AppleModelKind.privateCloud.displayName).font(.anuBody.weight(.medium))
                    Text(privateCloudLine(status))
                        .font(.anuLabel)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("privateCloudStatus")
                }
            }
        } footer: {
            Text("Big tasks go to Apple's larger model on Apple's servers, which keep nothing, before Gemini. There's a daily limit; when it's used up, Anu uses the next option.")
        }
    }

    private func privateCloudLine(_ status: AppleModelStatus) -> String {
        switch status {
        case .available: return "Ready for big tasks"
        case .approachingLimit: return "Ready · close to today's limit"
        case .unavailable(let reason): return reason.userText
        }
    }

    // MARK: - Downloadable (Google AI Edge Gallery) models

    @ViewBuilder
    private var downloadableSection: some View {
        Section {
            ForEach(downloadableModels) { model in
                let optionID = ModelCatalog.downloadablePrefix + model.id
                DownloadableModelRow(
                    model: model,
                    state: downloads.state(for: model),
                    isSelected: manager.selectedID == optionID,
                    onSelect: { select(optionID) },
                    onDownload: { downloads.download(model) },
                    onCancel: { downloads.cancel(model) },
                    onDelete: { delete(model, optionID: optionID) }
                )
            }
            Button {
                pickingModelFile = true
            } label: {
                Label(installing ? "Installing…" : "Install from a File", systemImage: "folder")
            }
            .disabled(installing)
            .accessibilityIdentifier("installModelFromFile")
            if let installNote {
                Text(installNote).font(.anuLabel).foregroundStyle(.secondary)
                    .accessibilityIdentifier("installModelNote")
            }
        } header: {
            Text("Downloadable")
        } footer: {
            Text("Gemma 4 from Google AI Edge Gallery's allowlist (open LiteRT-LM builds). E2B is the lighter sibling — smaller download, 8 GB of RAM instead of 12. Downloaded once over Wi-Fi, then runs fully on-device through the same LiteRT engine.")
        }
    }

    /// Allowlist models worth offering as a download. Whatever already ships in
    /// the bundle is covered by the "On this device" row above, so it's skipped
    /// here rather than listed twice.
    private var downloadableModels: [AllowlistModel] {
        ModelCatalog.allowlist.models.filter { !isBundled($0) }
    }

    /// True when this exact model ships inside the app bundle.
    private func isBundled(_ model: AllowlistModel) -> Bool {
        model.modelId == "litert-community/gemma-4-E4B-it-litert-lm"
            && Bundle.main.path(forResource: "gemma4e4b", ofType: "litertlm") != nil
    }

    private var showTokenField: Bool {
        downloadableModels.contains { $0.requiresAuth }
    }

    @ViewBuilder
    private var tokenSection: some View {
        Section {
            #if os(iOS)
            SecureField("hf_… access token", text: tokenBinding)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            #else
            SecureField("hf_… access token", text: tokenBinding)
                .autocorrectionDisabled()
            #endif
        } header: {
            Text("Hugging Face token")
        } footer: {
            Text("Gated Google models need a free Hugging Face token with the model license accepted. Create one at huggingface.co/settings/tokens. Stored only on this device.")
        }
    }

    private var tokenBinding: Binding<String> {
        Binding(
            get: { downloads.huggingFaceToken ?? "" },
            set: { downloads.huggingFaceToken = $0 }
        )
    }

    private func select(_ optionID: String) {
        manager.select(optionID)
        Task { await AgentOrchestrator.shared.switchActiveModel() }
    }

    private func delete(_ model: AllowlistModel, optionID: String) {
        downloads.delete(model)
        // If the deleted model was the active choice, fall back to Automatic so
        // the orchestrator doesn't keep pointing at a now-missing file.
        if manager.selectedID == optionID {
            manager.select("automatic")
            Task { await AgentOrchestrator.shared.switchActiveModel() }
        }
    }
}

// MARK: - Row (fixed entries)

private struct ModelRow: View {
    let option: ModelOption
    let availability: ModelAvailability
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Space.base) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.tight) {
                        Text(option.displayName).font(.anuBody.weight(.medium))
                        Text(option.family).font(.anuLabel)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Space.tight).padding(.vertical, Space.hair)
                            .background(Color.anuFill6)
                            .clipShape(Capsule())
                    }
                    Text("\(option.sizeText) · \(option.ramText) · \(option.speedText)")
                        .font(.anuLabel)
                        .foregroundStyle(.secondary)
                    statusLine
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.anuAccent)
                        .accessibilityLabel("Active model")
                }
            }
            .contentShape(Rectangle())
            .opacity(availability.isReady ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(!availability.isReady)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch availability {
        case .ready:
            EmptyView()
        case .needsDownload:
            Label("Not downloaded", systemImage: "arrow.down.circle")
                .font(.anuLabel).foregroundStyle(.tertiary)
        case .unsupported(let reason):
            Label(reason, systemImage: "exclamationmark.circle")
                .font(.anuLabel).foregroundStyle(.orange)
        }
    }
}

// MARK: - Row (downloadable entries)

private struct DownloadableModelRow: View {
    let model: AllowlistModel
    let state: ModelDownloadManager.State
    let isSelected: Bool
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    private var isDownloaded: Bool { if case .downloaded = state { return true }; return false }

    var body: some View {
        HStack(spacing: Space.base) {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.tight) {
                    Text(model.name).font(.anuBody.weight(.medium))
                    if model.supportsImage { chip("Vision") }
                    if model.supportsAudio { chip("Audio") }
                    if model.requiresAuth, !isDownloaded {
                        Image(systemName: "lock.fill").font(.anuLabel).foregroundStyle(.tertiary)
                            .accessibilityLabel("Gated — token required")
                    }
                }
                Text("\(ModelCatalog.gbText(model.sizeInBytes)) · \(model.minDeviceMemoryInGb.map { "≥ \($0) GB RAM" } ?? "—")")
                    .font(.anuLabel).foregroundStyle(.secondary)
                stateLine
            }
            Spacer(minLength: 0)
            trailingControl
        }
        .contentShape(Rectangle())
        .opacity(isDownloaded ? 1 : 0.9)
        .onTapGesture { if isDownloaded { onSelect() } }
        .swipeActions(edge: .trailing) {
            if isDownloaded {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var stateLine: some View {
        switch state {
        case .downloading(let progress):
            if progress < 0 {
                HStack(spacing: Space.tight) { ProgressView().controlSize(.small); Text("Downloading…") }
                    .font(.anuLabel).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: Space.hair) {
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))% of \(ModelCatalog.gbText(model.sizeInBytes))")
                        .font(.anuLabel).foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.anuLabel).foregroundStyle(.orange)
        case .downloaded:
            Label("On device", systemImage: "checkmark.seal.fill")
                .font(.anuLabel).foregroundStyle(.green)
        case .notDownloaded:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch state {
        case .downloaded:
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.anuAccent).accessibilityLabel("Active model")
            } else {
                Button("Use", action: onSelect)
                    .buttonStyle(.bordered).controlSize(.small)
            }
        case .downloading:
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill").font(.anuHeading)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("Cancel download")
        case .notDownloaded:
            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle").font(.anuTitle)
            }
            .buttonStyle(.plain).foregroundStyle(Color.anuAccent)
            .accessibilityLabel("Download \(model.name)")
        case .failed:
            Button(action: onDownload) {
                Image(systemName: "arrow.clockwise.circle").font(.anuTitle)
            }
            .buttonStyle(.plain).foregroundStyle(.orange)
            .accessibilityLabel("Retry download")
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.anuLabel)
            .padding(.horizontal, Space.tight).padding(.vertical, Space.hair)
            .background(Color.anuFill6)
            .clipShape(Capsule())
            .foregroundStyle(.secondary)
    }
}
