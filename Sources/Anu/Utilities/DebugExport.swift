#if DEBUG
import Foundation

/// DEBUG builds only: writes a plain-text copy of the chats, memory, privacy
/// ledger and Activity to `Documents/DebugExport/` so a developer can pull it
/// off a test phone (`devicectl device copy from --domain-type
/// appDataContainer`). The stores themselves stay encrypted (SecureFile); this
/// copy exists only after the user taps Export, carries no photo bytes, is
/// excluded from backup, and Delete removes it. Release builds don't contain
/// this type at all.
@MainActor
enum DebugExport {
    nonisolated static let fileName = "anu-debug-export.json"

    nonisolated static var directory: URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("DebugExport", isDirectory: true)
    }

    struct Export: Codable {
        let exportedAt: Date
        let app: String
        let chats: [Chat]
        let memory: [MemoryFact]
        let privacyLedger: [PrivacyEvent]
        let activity: [ToolAuditEntry]
        /// What AlarmKit holds for Anu right now (alarm debugging).
        var alarms: AlarmReport? = nil
        /// Parts left out because they couldn't be written, and why.
        var problems: [String]? = nil
    }

    struct AlarmReport: Codable, Equatable {
        let permission: String
        let scheduled: [String]
    }

    struct Chat: Codable {
        let id: UUID
        let name: String
        let createdAt: Date
        let updatedAt: Date
        let ephemeral: Bool
        let messages: [Message]
    }

    /// A message without its photo bytes (only how many there were).
    struct Message: Codable {
        let role: String
        let content: String
        let timestamp: Date
        let label: String?
        let details: AnswerDetails?
        let reasoning: String?
        let receipts: [ActionReceipt]?
        let photoCount: Int
        let hasDocument: Bool
        let voiceNote: VoiceNoteInfo?
    }

    struct Result: Equatable {
        let url: URL
        let chats: Int
        let messages: Int
        let bytes: Int
    }

    /// Builds the export from the given stores (injectable for tests).
    static func build(sessions: SessionStore,
                      memory: [MemoryFact],
                      ledger: [PrivacyEvent],
                      activity: [ToolAuditEntry],
                      now: Date = Date()) -> Export {
        let index = sessions.loadIndex() ?? SessionIndex()
        let chats = index.sessions.map { session -> Chat in
            let snapshot = sessions.conversationStore(for: session.id).load()
            let messages = (snapshot?.messages ?? []).map { m in
                Message(role: m.role.rawValue, content: m.content, timestamp: m.timestamp,
                        label: m.label, details: m.details, reasoning: m.reasoning,
                        receipts: m.receipts,
                        photoCount: (m.photos?.count ?? 0) + (m.imageData == nil ? 0 : 1),
                        hasDocument: m.document != nil, voiceNote: m.voiceNote)
            }
            return Chat(id: session.id, name: session.name, createdAt: session.createdAt,
                        updatedAt: session.updatedAt, ephemeral: session.ephemeral, messages: messages)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return Export(exportedAt: now, app: "Anu \(version) (DEBUG)", chats: chats,
                      memory: memory, privacyLedger: ledger, activity: activity)
    }

    /// Writes the current app state and returns where it went.
    @discardableResult
    static func writeCurrent(to directory: URL = DebugExport.directory) throws -> Result {
        let export = build(sessions: SessionStore(),
                           memory: MemoryStore.shared.facts,
                           ledger: PrivacyLedger.shared.events,
                           activity: ToolAuditLog.shared.entries)
        var withAlarms = export
        withAlarms.alarms = alarmReport()
        return try write(withAlarms, to: directory)
    }

    static func alarmReport() -> AlarmReport? {
        guard let permission = AlarmPermission.current else { return nil }
        return AlarmReport(permission: String(describing: permission), scheduled: AlarmPermission.scheduledSummaries())
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    /// The export as JSON. A part that can't be encoded is left out and named
    /// in `problems`, so one bad record never stops the whole export.
    static func encode(_ export: Export) -> (Data, Export) {
        let encoder = encoder
        if let data = try? encoder.encode(export) { return (data, export) }
        var problems: [String] = []
        func keep<T: Encodable>(_ items: [T], _ name: String) -> [T] {
            items.enumerated().compactMap { i, item in
                do { _ = try encoder.encode(item); return item } catch {
                    problems.append("\(name)[\(i)]: \(String(describing: error))"); return nil
                }
            }
        }
        let chats = export.chats.map { chat -> Chat in
            Chat(id: chat.id, name: chat.name, createdAt: chat.createdAt, updatedAt: chat.updatedAt,
                 ephemeral: chat.ephemeral, messages: keep(chat.messages, "chat \(chat.name) message"))
        }
        var cleaned = Export(exportedAt: export.exportedAt, app: export.app, chats: chats,
                             memory: keep(export.memory, "memory"),
                             privacyLedger: keep(export.privacyLedger, "privacyLedger"),
                             activity: keep(export.activity, "activity"))
        cleaned.alarms = export.alarms
        cleaned.problems = problems
        let data = (try? encoder.encode(cleaned)) ?? Data("{\"problems\":[\"export could not be encoded\"]}".utf8)
        return (data, cleaned)
    }

    static func write(_ export: Export, to directory: URL) throws -> Result {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (data, export) = encode(export)
        let url = directory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            // Replacing an old copy can fail; start from a clean file.
            try? FileManager.default.removeItem(at: url)
            try data.write(to: url, options: [.completeFileProtection])
        }
        SecureFile.excludeFromBackup(url)
        return Result(url: url, chats: export.chats.count,
                      messages: export.chats.reduce(0) { $0 + $1.messages.count }, bytes: data.count)
    }

    static func delete(in directory: URL = DebugExport.directory) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }

    static func exists(in directory: URL = DebugExport.directory) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path)
    }
}
#endif

#if DEBUG
import SwiftUI

/// Settings → Developer (DEBUG builds only).
struct DebugExportSection: View {
    @State private var status: String?
    @State private var exists = DebugExport.exists()

    var body: some View {
        Section {
            Button("Export chats for debugging") {
                do {
                    let result = try DebugExport.writeCurrent()
                    status = "Exported \(result.chats) chats, \(result.messages) messages "
                        + "(\(ByteCountFormatter.string(fromByteCount: Int64(result.bytes), countStyle: .file)))."
                } catch {
                    status = "Export failed: \(String(describing: error))"
                }
                exists = DebugExport.exists()
            }
            .accessibilityIdentifier("debugExportButton")
            if exists {
                Button("Delete debug export", role: .destructive) {
                    DebugExport.delete()
                    exists = DebugExport.exists()
                    status = "Deleted."
                }
                .accessibilityIdentifier("debugExportDeleteButton")
            }
            if let status {
                Text(status).font(.anuLabel).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("debugExportStatus")
            }
        } header: {
            Text("Developer")
        } footer: {
            Text("Debug builds only. Writes a plain copy of your chats, memory, Privacy Ledger and Activity to Anu's Documents folder so it can be read from a connected Mac. Photos aren't included. Delete it when you're done.")
        }
    }
}
#endif
