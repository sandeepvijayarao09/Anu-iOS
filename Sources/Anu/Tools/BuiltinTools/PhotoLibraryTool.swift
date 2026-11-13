import Foundation
import Photos

/// Reads (count/recent) and adds photos to the user's library via PhotoKit.
/// Requires Photos access; denied access returns a graceful message.
struct PhotoLibraryTool: Tool {
    let name = "photos"
    let description = """
    Work with the photo library. action 'count' returns how many photos there are; \
    'recent' lists the most recent ones; 'save' adds an image file to the library \
    (needs 'path').
    """

    var parameters: JSONSchema? {
        .object(
            description: "Photos parameters",
            properties: [
                "action": .string(description: "count, recent, or save", enumValues: ["count", "recent", "save"]),
                "path": .string(description: "Path to an image file (required for save)"),
            ],
            required: ["action"]
        )
    }

    static func authorized() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    func execute(arguments: JSONValue) async throws -> String {
        let action = (arguments["action"]?.stringValue ?? "count").lowercased()
        guard await Self.authorized() else {
            return "Photos access not granted. Enable it in Settings → Privacy → Photos."
        }

        switch action {
        case "count":
            let count = PHAsset.fetchAssets(with: .image, options: nil).count
            return "You have \(count) photo\(count == 1 ? "" : "s")."

        case "recent":
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            opts.fetchLimit = 5
            let assets = PHAsset.fetchAssets(with: .image, options: opts)
            guard assets.count > 0 else { return "No photos found." }
            let formatter = AnuDate.dateOnly
            var lines: [String] = []
            assets.enumerateObjects { asset, _, _ in
                let date = asset.creationDate.map { formatter.string(from: $0) } ?? "unknown date"
                lines.append("• Photo from \(date)")
            }
            return "Recent photos:\n" + lines.joined(separator: "\n")

        case "save":
            guard let path = arguments["path"]?.stringValue, !path.isEmpty else {
                throw ToolError.missingArgument("path")
            }
            let url = URL(fileURLWithPath: path)
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
                return "Saved the image to your photo library."
            } catch {
                return "Couldn't save the image: \(error.localizedDescription)"
            }

        default:
            throw ToolError.invalidArgument("action", expected: "'count', 'recent', or 'save'")
        }
    }
}

// MARK: - Broker policy

extension PhotoLibraryTool {
    func risk(for arguments: JSONValue) -> RiskTier {
        ToolDescribing.action(arguments) == "save" ? .writePrivate : .read
    }
    func describe(_ arguments: JSONValue) -> String {
        switch ToolDescribing.action(arguments) {
        case "save": return "Save an image to your photo library"
        case "recent": return "Look at your recent photos"
        default: return "Count your photos"
        }
    }
}
