import Foundation

/// Photos and PDFs shared into Anu from another app (ADR-094, ADR-095). The
/// share extension can't reach the app's data key, so it hands each file over
/// in the App Group container, protected and excluded from backup; the app
/// reads it into the composer and deletes it at once, as Android deletes its
/// camera file once read. Nothing is kept here.
enum SharedMedia {
    static var directory: URL { AppGroup.containerURL.appendingPathComponent("SharedMedia", isDirectory: true) }

    /// Writes one shared file; returns its hand-off name ("<uuid>--<file name>").
    static func put(_ data: Data, fileName: String, directory: URL = directory) -> String? {
        let cleaned = String(fileName.map { $0 == "/" || $0 == ":" ? "-" : $0 }.prefix(120))
        let name = UUID().uuidString + "--" + (cleaned.hasPrefix(".") ? "file" + cleaned : cleaned)
        var url = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            return name
        } catch {
            return nil
        }
    }

    /// Reads a handed-off file and deletes it.
    static func take(_ name: String, directory: URL = directory) -> Data? {
        // Names come from the inbox: never let one point outside the folder.
        guard !name.contains("/"), !name.hasPrefix(".") else { return nil }
        let url = directory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: url) }
        return try? Data(contentsOf: url)
    }

    static func isPDF(_ name: String) -> Bool { name.lowercased().hasSuffix(".pdf") }

    /// The file's own name, as shared.
    static func displayName(_ name: String) -> String {
        name.range(of: "--").map { String(name[$0.upperBound...]) } ?? name
    }
}
