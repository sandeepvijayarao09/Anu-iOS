import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#if canImport(PDFKit)
import PDFKit
#endif

// MARK: - Clipboard (cross-platform)

/// Reads or sets the system clipboard. UIPasteboard on iOS, NSPasteboard on macOS.
struct ClipboardTool: Tool {
    let name = "clipboard"
    let description = "Read or set the clipboard. action 'get' returns the current text; action 'set' needs 'text'."

    var parameters: JSONSchema? {
        .object(
            description: "Clipboard parameters",
            properties: [
                "action": .string(description: "get or set", enumValues: ["get", "set"]),
                "text": .string(description: "Text to copy (required for set)"),
            ],
            required: ["action"]
        )
    }

    func execute(arguments: JSONValue) async throws -> String {
        let action = (arguments["action"]?.stringValue ?? "get").lowercased()
        switch action {
        case "get":
            let current = await Clipboard.get()
            return (current?.isEmpty == false) ? "Clipboard: \(current!)" : "The clipboard is empty."
        case "set":
            guard let text = arguments["text"]?.stringValue, !text.isEmpty else {
                throw ToolError.missingArgument("text")
            }
            await Clipboard.set(text)
            return "Copied to the clipboard."
        default:
            throw ToolError.invalidArgument("action", expected: "'get' or 'set'")
        }
    }
}

/// Thin cross-platform pasteboard shim so the tool + tests are platform-agnostic.
enum Clipboard {
    static func get() async -> String? {
        #if canImport(UIKit)
        return await MainActor.run { UIKit.UIPasteboard.general.string }
        #elseif canImport(AppKit)
        return AppKit.NSPasteboard.general.string(forType: .string)
        #else
        return nil
        #endif
    }

    static func set(_ text: String) async {
        #if canImport(UIKit)
        await MainActor.run { UIKit.UIPasteboard.general.string = text }
        #elseif canImport(AppKit)
        let pb = AppKit.NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        #endif
    }
}

// MARK: - Keep screen awake (iOS)

#if canImport(UIKit)
/// Prevents/allows the device auto-lock (idle timer). iOS only.
struct KeepAwakeTool: Tool {
    let name = "keep_awake"
    let description = "Keep the screen awake (prevent auto-lock) or allow it to sleep. action 'on' or 'off'."

    var parameters: JSONSchema? {
        .object(
            description: "Keep-awake parameters",
            properties: ["action": .string(description: "on or off", enumValues: ["on", "off"])],
            required: ["action"]
        )
    }

    func execute(arguments: JSONValue) async throws -> String {
        let on = (arguments["action"]?.stringValue ?? "").lowercased() == "on"
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = on }
        return on ? "The screen will stay awake." : "The screen can sleep normally now."
    }
}
#endif

// MARK: - Files (app Documents sandbox — pure Foundation, cross-platform)

/// Read/write/list plain-text files in the app's Documents folder. Stays inside
/// the sandbox (no arbitrary filesystem access); names are sanitized to a leaf.
struct FilesTool: Tool {
    let name = "files"
    let description = """
    Work with text files in the app's Documents folder. action 'write' needs 'name' and 'content'; \
    'read' needs 'name'; 'list' lists saved files.
    """

    var parameters: JSONSchema? {
        .object(
            description: "File parameters",
            properties: [
                "action": .string(description: "read, write, or list", enumValues: ["read", "write", "list"]),
                "name": .string(description: "File name (leaf only, e.g. 'notes.txt')"),
                "content": .string(description: "Text content (required for write)"),
            ],
            required: ["action"]
        )
    }

    static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// Reduce any provided name to a safe leaf inside Documents (no traversal).
    static func safeURL(for name: String) -> URL? {
        let leaf = (name as NSString).lastPathComponent
        guard !leaf.isEmpty, leaf != "..", leaf != "." else { return nil }
        return documentsDirectory().appendingPathComponent(leaf)
    }

    func execute(arguments: JSONValue) async throws -> String {
        let action = (arguments["action"]?.stringValue ?? "list").lowercased()
        switch action {
        case "list":
            let files = (try? FileManager.default.contentsOfDirectory(
                atPath: Self.documentsDirectory().path)) ?? []
            return files.isEmpty ? "No files saved." : "Files:\n" + files.sorted().joined(separator: "\n")
        case "read":
            guard let name = arguments["name"]?.stringValue, let url = Self.safeURL(for: name) else {
                throw ToolError.missingArgument("name")
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return "Couldn't read \"\(name)\" — it may not exist."
            }
            return text
        case "write":
            guard let name = arguments["name"]?.stringValue, let url = Self.safeURL(for: name) else {
                throw ToolError.missingArgument("name")
            }
            guard let content = arguments["content"]?.stringValue else {
                throw ToolError.missingArgument("content")
            }
            do { try content.write(to: url, atomically: true, encoding: .utf8) }
            catch { return "Failed to write \"\(name)\": \(error.localizedDescription)" }
            return "Saved \"\(name)\" (\(content.count) characters)."
        default:
            throw ToolError.invalidArgument("action", expected: "'read', 'write', or 'list'")
        }
    }
}

// MARK: - Read a PDF (PDFKit)

#if canImport(PDFKit)
/// Extracts text from a PDF file — fully on-device. Optional 1-based 'page'.
struct ReadPDFTool: Tool {
    let name = "read_pdf"
    let description = """
    Extract the text from a PDF file. Provide 'path' to a .pdf; optional 'page' \
    (1-based) reads a single page instead of the whole document.
    """

    var parameters: JSONSchema? {
        .object(
            description: "PDF parameters",
            properties: [
                "path": .string(description: "Path to a .pdf file"),
                "page": .string(description: "Optional 1-based page number"),
            ],
            required: ["path"]
        )
    }

    func execute(arguments: JSONValue) async throws -> String {
        guard let path = arguments["path"]?.stringValue, !path.isEmpty else {
            throw ToolError.missingArgument("path")
        }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
            return "Couldn't open that PDF."
        }
        if let pageStr = arguments["page"]?.stringValue, let n = Int(pageStr) {
            guard n >= 1, n <= doc.pageCount, let page = doc.page(at: n - 1) else {
                return "That PDF has \(doc.pageCount) page(s); page \(n) is out of range."
            }
            let text = page.string ?? ""
            return text.isEmpty ? "No text on page \(n)." : text
        }
        let text = doc.string ?? ""
        return text.isEmpty ? "No extractable text in that PDF (it may be scanned images)." : text
    }
}
#endif

// MARK: - Broker policy

extension ClipboardTool {
    func risk(for arguments: JSONValue) -> RiskTier {
        ToolDescribing.action(arguments) == "set" ? .writePrivate : .read
    }
    func describe(_ arguments: JSONValue) -> String {
        guard ToolDescribing.action(arguments) == "set" else { return "Read the clipboard" }
        return "Copy " + ToolDescribing.quoted(ToolDescribing.text(arguments, "text") ?? "") + " to the clipboard"
    }
    /// Another app put it there.
    func returnsUntrustedContent(for arguments: JSONValue) -> Bool {
        ToolDescribing.action(arguments) != "set"
    }
    var editableFields: [EditableField] { [EditableField(key: "text", label: "Text", kind: .text)] }
}

#if canImport(UIKit)
extension KeepAwakeTool {
    func risk(for arguments: JSONValue) -> RiskTier { .writePrivate }
    func describe(_ arguments: JSONValue) -> String {
        ToolDescribing.action(arguments) == "off" ? "Let the screen sleep again" : "Keep the screen awake"
    }
}
#endif

extension FilesTool {
    func risk(for arguments: JSONValue) -> RiskTier {
        ToolDescribing.action(arguments) == "write" ? .writePrivate : .read
    }
    func describe(_ arguments: JSONValue) -> String {
        let file = ToolDescribing.text(arguments, "name") ?? "a file"
        switch ToolDescribing.action(arguments) {
        case "write": return "Save \(file) in Anu's files"
        case "read": return "Read \(file) from Anu's files"
        default: return "List Anu's files"
        }
    }
    func returnsUntrustedContent(for arguments: JSONValue) -> Bool {
        ToolDescribing.action(arguments) == "read"
    }
    var editableFields: [EditableField] { [EditableField(key: "content", label: "Content", kind: .text)] }
}

#if canImport(PDFKit)
extension ReadPDFTool {
    func describe(_ arguments: JSONValue) -> String {
        "Read " + (ToolDescribing.text(arguments, "path").map { ($0 as NSString).lastPathComponent } ?? "a PDF")
    }
    /// A document can say anything.
    func returnsUntrustedContent(for arguments: JSONValue) -> Bool { true }
}
#endif
