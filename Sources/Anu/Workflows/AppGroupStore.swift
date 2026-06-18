import Foundation

/// The App Group shared by the app, the widget, and the share extension. Its
/// container is where Workflows and the request inbox live so every process
/// sees the same data. Falls back to the app's own Documents directory when the
/// group container isn't available (unit tests, or a build without the
/// entitlement) so nothing crashes.
enum AppGroup {
    static let id = "group.com.anu.app"

    static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}

/// Tiny Codable-JSON-on-disk helper, the same pattern as `ConversationStore` /
/// `PrivacyLedgerStore`, but rooted in the App Group container.
struct AppGroupFile<Value: Codable> {
    private let url: URL

    init(_ name: String, directory: URL = AppGroup.containerURL) {
        self.url = directory.appendingPathComponent(name)
    }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        // App Group files are read/written by extensions that can run while the
        // device is locked (post first-unlock), so use the until-first-auth class
        // rather than .complete (which would block locked-state access).
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
