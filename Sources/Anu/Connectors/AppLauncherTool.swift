import Foundation

/// Opens a URL on the device. The real implementation defers to
/// `UIApplication.open`; tests inject a fake to assert the constructed URL
/// without actually launching anything.
protocol URLOpening: Sendable {
    func open(_ url: URL) async -> Bool
}

#if canImport(UIKit)
import UIKit

/// Opens URLs via UIKit. Uses `open(_:options:completionHandler:)` (no
/// `canOpenURL` precheck — that needs `LSApplicationQueriesSchemes`, which this
/// project can't declare without an Info.plist file).
struct SystemURLOpener: URLOpening {
    func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                UIApplication.shared.open(url, options: [:]) { success in
                    continuation.resume(returning: success)
                }
            }
        }
    }
}
#endif

// MARK: - Run Shortcut

/// Runs one of the user's Apple Shortcuts by name via the `shortcuts://` scheme.
struct ShortcutsTool: Tool {
    let name = "run_shortcut"
    let description = "Runs one of the user's Apple Shortcuts by name, optionally passing text input. Use for automations the user has already set up."

    let appConfig: AppLauncherConfig
    let opener: any URLOpening

    init(appConfig: AppLauncherConfig, opener: any URLOpening) {
        self.appConfig = appConfig
        self.opener = opener
    }

    var parameters: JSONSchema? {
        .object(
            description: "Shortcut parameters",
            properties: [
                "name": .string(description: "Exact name of the Shortcut to run"),
                "input": .string(description: "Optional text passed to the Shortcut"),
            ],
            required: ["name"]
        )
    }

    var sideEffect: ToolSideEffect { .external(capability: .appLaunch) }

    func execute(arguments: JSONValue) async throws -> String {
        guard let shortcut = arguments["name"]?.stringValue, !shortcut.isEmpty else {
            throw ToolError.missingArgument("name")
        }
        guard appConfig.allows(scheme: "shortcuts") else {
            return "The 'shortcuts' scheme isn't in the allowed list (Settings → Connectors)."
        }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        var items = [URLQueryItem(name: "name", value: shortcut)]
        if let input = arguments["input"]?.stringValue, !input.isEmpty {
            items.append(URLQueryItem(name: "input", value: "text"))
            items.append(URLQueryItem(name: "text", value: input))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw ToolError.executionFailed("Could not build the Shortcut URL")
        }
        await PrivacyLedger.shared.record(
            destination: .appLaunch(scheme: "shortcuts", target: url.absoluteString),
            payload: url.absoluteString,
            redactions: 0
        )
        let ok = await opener.open(url)
        return ok
            ? "Ran Shortcut \"\(shortcut)\" (\(url.absoluteString))."
            : "Couldn't run Shortcut \"\(shortcut)\" — check the name is exact."
    }
}

// MARK: - Open app / URL

/// Opens another app or a web/x-callback URL, restricted to the allowed schemes.
struct OpenAppTool: Tool {
    let name = "open_app"
    let description = """
    Opens another app or a URL to perform a device action. Provide a full URL with \
    a scheme. Common patterns: call → 'tel:5551234'; text → 'sms:5551234&body=on my way'; \
    email → 'mailto:alex@example.com?subject=Hi&body=...'; directions/navigation → \
    'maps://?daddr=San+Francisco+Airport'; find a place → 'maps://?q=coffee+near+me'; \
    play music → 'music://'; a website → 'https://example.com'. URL-encode spaces as '+' or '%20'.
    """

    let appConfig: AppLauncherConfig
    let opener: any URLOpening

    init(appConfig: AppLauncherConfig, opener: any URLOpening) {
        self.appConfig = appConfig
        self.opener = opener
    }

    var parameters: JSONSchema? {
        .object(
            description: "Open-URL parameters",
            properties: ["url": .string(description: "Full URL with a scheme, e.g. 'maps://?q=coffee'")],
            required: ["url"]
        )
    }

    var sideEffect: ToolSideEffect { .external(capability: .appLaunch) }

    func execute(arguments: JSONValue) async throws -> String {
        guard let raw = arguments["url"]?.stringValue,
              let url = URL(string: raw), let scheme = url.scheme, !scheme.isEmpty else {
            throw ToolError.invalidArgument("url", expected: "a valid URL with a scheme")
        }
        guard appConfig.allows(scheme: scheme) else {
            return "The '\(scheme)' scheme isn't in the allowed list. Add it in Settings → Connectors."
        }
        await PrivacyLedger.shared.record(
            destination: .appLaunch(scheme: scheme, target: url.absoluteString),
            payload: url.absoluteString,
            redactions: 0
        )
        let ok = await opener.open(url)
        return ok ? "Opened \(url.absoluteString)." : "Couldn't open \(url.absoluteString)."
    }
}

// MARK: - Broker policy

extension ShortcutsTool {
    /// A Shortcut can do anything, including send messages.
    func risk(for arguments: JSONValue) -> RiskTier { .writeExternal }
    func describe(_ arguments: JSONValue) -> String {
        let name = ToolDescribing.quoted(ToolDescribing.text(arguments, "name") ?? "a shortcut")
        guard let input = ToolDescribing.text(arguments, "input") else { return "Run your Shortcut \(name)" }
        return "Run your Shortcut \(name) with " + ToolDescribing.quoted(input)
    }
    func approvalNote(for arguments: JSONValue) -> String? { "Shortcuts can act outside Anu" }
    var editableFields: [EditableField] {
        [EditableField(key: "input", label: "Input", kind: .text, optional: true)]
    }
}

extension OpenAppTool {
    func risk(for arguments: JSONValue) -> RiskTier { .writeExternal }
    func describe(_ arguments: JSONValue) -> String {
        "Open " + (ToolDescribing.text(arguments, "url") ?? "an app")
    }
    /// A web link sends a request to its host; other schemes stay on the phone.
    func sendsTo(_ arguments: JSONValue) -> String? {
        guard let raw = ToolDescribing.text(arguments, "url"), let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url.host
    }
    func approvalNote(for arguments: JSONValue) -> String? {
        sendsTo(arguments) == nil ? "This hands off to another app" : nil
    }
}
