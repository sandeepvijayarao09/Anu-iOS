import Foundation
import Security
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Settings → Delete All My Data (App Store Review Guideline 5.1.1, and
/// the promise that everything Anu keeps is the user's to remove).
///
/// What goes: chats and sessions, memory, the privacy ledger, the activity
/// log, the vault and every saved key or sign-in (Gmail, MCP OAuth), voice
/// notes, the "Hey Anu" samples, added skills, workflows, notes and files Anu saved, the App Group
/// hand-offs (share sheet, keyboard, Rewrite with Anu), settings, Spotlight
/// entries and scheduled workflow reminders.
///
/// What stays: the downloaded Gemma model and its prepared GPU cache (no
/// personal data, and gigabytes to fetch again; Settings → On-device Model
/// deletes them), and alarms already handed to the Clock (they are the
/// system's; the Clock app removes them).
///
/// Objects already in memory can write a stale copy back before the app is
/// closed, so the erase leaves a marker and runs once more, before anything
/// loads, on the next launch (`finishPendingErase`).
struct DataEraser {
    /// A directory whose contents are deleted. `keep` lists top-level names
    /// to leave; `only`, when set, limits the erase to those names.
    struct Location {
        let directory: URL
        var keep: Set<String> = []
        var only: Set<String>? = nil
    }

    var locations: [Location]
    /// The UserDefaults domain to remove (the app's bundle identifier).
    var defaultsDomain: String?
    var defaults: UserDefaults = .standard
    /// Keychain services Anu writes; only these are deleted.
    var keychainServices: [String]
    /// Written after an erase; its presence makes the next launch erase again.
    var markerURL: URL

    /// Names Anu writes into Documents, Application Support and the App
    /// Group container. On iOS the whole sandbox is Anu's, so it is emptied;
    /// the Mac app isn't sandboxed (its "Documents" is the user's own folder),
    /// so there only these are removed.
    static let knownDocuments: Set<String> = [
        "memory.json", "sessions", "conversation.json", "privacy_ledger.json", "DebugExport",
        "notes.json",
        // App Group fallbacks (no group container on the Mac):
        "inbox.json", "workflows.json", "keyboard-status.json", "writing-handoff.json",
        "SharedMedia", "SharedVoiceNotes",
    ]
    static let knownApplicationSupport: Set<String> = [
        "tool-audit.json", "a2a_agents.json", "gmail_account.json", "VoiceNotes", "Skills",
        WakeVoiceStore.folderName,   // "Hey Anu" samples (ADR-121)
    ]
    /// Not personal data, and large: kept (see the type comment).
    static let modelFolders: Set<String> = ["Models"]
    static let engineCacheFolders: Set<String> = ["LiteRTLM"]

    static let anuKeychainServices = [
        "com.anu.app",          // KeychainStore: connector secrets, OAuth tokens
        "com.gemmaagent.app",   // pre-rename KeychainStore service
        "com.anu.app.vault",    // Vault items + the local data-encryption key
        "com.anu.app.shared",   // App Group key for share-sheet voice notes
    ]

    /// The real locations for this platform.
    static var live: DataEraser {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let group = fm.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)
        var locations: [Location] = []
        #if os(iOS)
        if let docs { locations.append(Location(directory: docs)) }
        if let support { locations.append(Location(directory: support, keep: modelFolders)) }
        if let caches { locations.append(Location(directory: caches, keep: engineCacheFolders)) }
        locations.append(Location(directory: fm.temporaryDirectory))
        // The group container's Library holds the system's own preferences
        // and caches for the group; Anu writes only at its top level.
        if let group { locations.append(Location(directory: group, keep: ["Library"])) }
        #else
        if let docs { locations.append(Location(directory: docs, only: knownDocuments)) }
        if let support { locations.append(Location(directory: support, only: knownApplicationSupport)) }
        if let group { locations.append(Location(directory: group, only: knownDocuments)) }
        #endif
        return DataEraser(locations: locations,
                          defaultsDomain: Bundle.main.bundleIdentifier,
                          keychainServices: anuKeychainServices,
                          markerURL: library.appendingPathComponent(".anu-erase-pending"))
    }

    /// Deletes files, settings and Keychain items. Returns how many files or
    /// folders were removed. Safe to call repeatedly.
    @discardableResult
    func eraseStoredData() -> Int {
        let fm = FileManager.default
        var removed = 0
        for location in locations {
            let names = (try? fm.contentsOfDirectory(atPath: location.directory.path)) ?? []
            for name in names where !location.keep.contains(name) {
                if let only = location.only, !only.contains(name) { continue }
                let url = location.directory.appendingPathComponent(name)
                if url.standardizedFileURL == markerURL.standardizedFileURL { continue }
                if (try? fm.removeItem(at: url)) != nil { removed += 1 }
            }
        }
        if let defaultsDomain {
            defaults.removePersistentDomain(forName: defaultsDomain)
        }
        for service in keychainServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            SecItemDelete(query as CFDictionary)
        }
        return removed
    }

    var isPending: Bool { FileManager.default.fileExists(atPath: markerURL.path) }

    func markPending() {
        try? FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: markerURL.path, contents: Data())
    }

    func clearPending() { try? FileManager.default.removeItem(at: markerURL) }

    /// Call first thing at launch, before any store loads from disk.
    static func finishPendingErase(_ eraser: DataEraser = .live) {
        guard eraser.isPending else { return }
        eraser.eraseStoredData()
        eraser.clearPending()
    }

    /// The whole erase, from Settings. Empties what's on screen, deletes
    /// everything stored, and arranges the second pass at next launch.
    @MainActor
    static func eraseEverything(_ eraser: DataEraser = .live) async {
        // In-memory stores first, so the UI empties and nothing they save
        // afterwards still holds the old data.
        MemoryStore.shared.deleteAll()
        PrivacyLedger.shared.clear()
        ToolAuditLog.shared.clear()
        Vault.shared.removeAll()
        WakeVoiceStore.shared.delete()

        #if canImport(CoreSpotlight)
        try? await CSSearchableIndex.default().deleteAllSearchableItems()
        #endif
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        #endif
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        URLCache.shared.removeAllCachedResponses()

        eraser.eraseStoredData()
        eraser.markPending()
    }
}
