import Foundation

/// Installs a model file the user already has (Android ADR-067): Settings →
/// Model → Install from a File. Only a file that is one of the catalog's own
/// models is kept, under its catalog name, so a renamed download ("gemma (1)
/// .litertlm") still works and nothing else is ever loaded.
///
/// Android matches the catalog file's SHA-256. The iOS catalog records sizes,
/// not hashes, so a file must instead start with LiteRT-LM's own marker and
/// match one catalog model's size, within the 1% that downloads allow too.
enum ModelFileInstaller {
    /// Every `.litertlm` file starts with these eight bytes.
    static let magic = Data("LITERTLM".utf8)

    enum Problem: Error, Equatable, LocalizedError {
        case unreadable
        case notAModel
        case unknownModel(sizeBytes: Int64)
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: return "Anu couldn't open that file."
            case .notAModel: return "That isn't a LiteRT-LM model file."
            case .unknownModel(let size):
                let gb = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                return "That model file (\(gb)) isn't one of the models Anu can run."
            case .copyFailed(let why): return "Anu couldn't save the model: \(why)"
            }
        }
    }

    /// The catalog model `url` is, by its header and size.
    static func identify(_ url: URL, among models: [AllowlistModel]) throws -> AllowlistModel {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Problem.unreadable }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: magic.count)) ?? Data()
        guard header == magic else { throw Problem.notAModel }
        let size = (try? handle.seekToEnd()).map(Int64.init) ?? 0
        let matches = models.filter { abs(Double(size - $0.sizeInBytes)) <= Double($0.sizeInBytes) * 0.01 }
        guard matches.count == 1, let model = matches.first else { throw Problem.unknownModel(sizeBytes: size) }
        return model
    }

    /// Copies `url` (from the file picker, so security-scoped) into place
    /// under the catalog name, replacing an earlier copy. Returns the model.
    static func install(_ url: URL, among models: [AllowlistModel], store: ModelDownloadStore) throws -> AllowlistModel {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let model = try identify(url, among: models)
        let destination = store.fileURL(for: model)
        let partial = destination.appendingPathExtension("installing")
        let fm = FileManager.default
        do {
            try store.ensureDirectory()
            try? fm.removeItem(at: partial)
            try fm.copyItem(at: url, to: partial)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: partial, to: destination)
        } catch {
            try? fm.removeItem(at: partial)
            throw Problem.copyFailed(error.localizedDescription)
        }
        // A model is large and can be fetched again: keep it out of backups.
        SecureFile.excludeFromBackup(destination)
        return model
    }
}
