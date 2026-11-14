import Foundation
import Combine

// MARK: - Tool audit

/// One broker decision: what a tool call was, and what happened to it.
struct ToolAuditEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let runID: UUID
    let toolName: String
    let risk: RiskTier
    /// The tool's own description of the call.
    let summary: String
    let destination: String?
    /// "ok", "ok, edited by you", "declined", "no answer in time", "failed: …",
    /// "blocked: …", "replayed", "cancelled".
    let outcome: String
    /// Nil when no approval was needed.
    let approved: Bool?
    var date = Date()
}

/// Every broker decision, newest first, kept on the device (Settings →
/// Activity). Capped so it can't grow without bound.
@MainActor
final class ToolAuditLog: ObservableObject {
    static let shared = ToolAuditLog()
    static let maxEntries = 500

    @Published private(set) var entries: [ToolAuditEntry] = []

    private let fileURL: URL?

    /// `fileURL` nil keeps the log in memory only (tests).
    init(fileURL: URL? = ToolAuditLog.defaultURL) {
        self.fileURL = fileURL
        if let fileURL, let data = SecureFile.read(fileURL),
           let saved = try? JSONDecoder().decode([ToolAuditEntry].self, from: data) {
            entries = saved
        }
    }

    func record(_ entry: ToolAuditEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? SecureFile.write(data, to: fileURL)
    }

    nonisolated static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("tool-audit.json")
    }
}
