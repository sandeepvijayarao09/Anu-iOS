import Foundation

/// Your own LiteRT-LM model files (Google AI Edge Gallery's "import a model"):
/// any `.litertlm` that isn't one of the catalog's, copied in from Files and
/// run through the same LiteRT-LM engine. Stored beside downloaded models in
/// `Models/Custom/`, kept out of backups, and chosen by the option id
/// `custom:<file name>`.
enum CustomModels {
    static let prefix = "custom:"

    struct Model: Equatable, Identifiable, Sendable {
        let fileName: String
        let sizeBytes: Int64
        var id: String { CustomModels.prefix + fileName }
        /// "my-model.litertlm" → "my-model".
        var name: String { (fileName as NSString).deletingPathExtension }
    }

    static func directory(_ store: ModelDownloadStore = ModelDownloadStore()) -> URL {
        store.directory.appendingPathComponent("Custom", isDirectory: true)
    }

    static func isCustom(_ optionID: String) -> Bool { optionID.hasPrefix(prefix) }

    /// The file an option id names, or nil when it isn't a custom id or the
    /// name would leave the folder.
    static func fileURL(for optionID: String, in directory: URL = directory()) -> URL? {
        guard isCustom(optionID) else { return nil }
        let name = String(optionID.dropFirst(prefix.count))
        guard name == safeName(name), !name.isEmpty else { return nil }
        return directory.appendingPathComponent(name)
    }

    /// The models present, by name.
    static func list(in directory: URL = directory()) -> [Model] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return urls.filter { $0.pathExtension == "litertlm" }.map { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return Model(fileName: url.lastPathComponent, sizeBytes: Int64(size))
        }.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    /// A file name with no path parts or odd characters, ending in .litertlm.
    static func safeName(_ raw: String) -> String {
        let base = (raw as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
        let cleaned = String(stem.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return (cleaned.isEmpty ? "model" : cleaned) + ".litertlm"
    }

    /// Copies a picked `.litertlm` (security-scoped) in, replacing a file of the
    /// same name. Checks the LiteRT-LM header first.
    static func install(_ url: URL, into directory: URL = directory()) throws -> Model {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ModelFileInstaller.Problem.unreadable }
        let header = (try? handle.read(upToCount: ModelFileInstaller.magic.count)) ?? Data()
        try? handle.close()
        guard header == ModelFileInstaller.magic else { throw ModelFileInstaller.Problem.notAModel }

        let fm = FileManager.default
        let name = safeName(url.lastPathComponent)
        let destination = directory.appendingPathComponent(name)
        let partial = destination.appendingPathExtension("installing")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fm.removeItem(at: partial)
            try fm.copyItem(at: url, to: partial)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: partial, to: destination)
        } catch {
            try? fm.removeItem(at: partial)
            throw ModelFileInstaller.Problem.copyFailed(error.localizedDescription)
        }
        SecureFile.excludeFromBackup(destination)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Model(fileName: name, sizeBytes: Int64(size))
    }

    static func delete(_ model: Model, in directory: URL = directory()) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(model.fileName))
    }
}
