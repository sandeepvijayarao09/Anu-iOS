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
    var requiresConfirmation: Bool { true }

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
    let description = "Opens another app or a URL on the device (maps, phone, mail, music, web links, x-callback URLs). Provide a full URL such as 'maps://?q=coffee', 'tel://5551234', or 'https://example.com'."

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
    var requiresConfirmation: Bool { true }

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
