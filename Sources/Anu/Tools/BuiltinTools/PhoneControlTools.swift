import Foundation

// MARK: - Phone controls (Android parity #16: ADR-076, ADR-099, ADR-107)
//
// Anu for Android's `connector:phone`, adapted to what iOS lets an app do:
// - the flashlight (AVCaptureDevice torch) and screen brightness (UIScreen),
//   private changes on the phone, so they run by themselves unless the turn
//   read content written by others;
// - opening an app by name, directions in Apple Maps and the share sheet,
//   through the app-launch switch in Settings → Connectors like `open_app`.
// Calls go through `contact_action`, timers and alarms through `set_timer`
// (AlarmKit where available), reminders through `reminders`.
// iOS has no public API for the volume or Do Not Disturb, so there is no tool
// for them: the model can't claim to have done it, and the Direct tier answers
// with the closest place to do it (Control Center, Focus).
//
// Every tool here throws when it can't act, so the receipt under the answer
// says Failed rather than Done (the broker reads a returned string as success).

// MARK: Flashlight

/// The camera's torch. Injectable so the tool is testable without hardware.
protocol TorchControlling: Sendable {
    /// Turns the torch on at `level` (0 to 1) or off. Throws when there is no
    /// torch or it is busy (the camera is in use).
    func setTorch(on: Bool, level: Double) async throws
}

#if os(iOS)
import AVFoundation

struct SystemTorch: TorchControlling {
    func setTorch(on: Bool, level: Double) async throws {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
            throw ToolError.executionFailed("This device has no flashlight.")
        }
        guard device.isTorchAvailable else {
            throw ToolError.executionFailed("The flashlight isn't available right now (the camera may be in use or the phone too warm).")
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if on {
            try device.setTorchModeOn(level: Float(min(max(level, 0.05), 1.0)))
        } else {
            device.torchMode = .off
        }
    }
}
#endif

struct FlashlightTool: Tool {
    let name = "phone_flashlight"
    let description = "Turn the phone's flashlight on or off. 'on' is true or false; optional 'percent' (1-100) for brightness."

    let torch: any TorchControlling

    init(torch: any TorchControlling) {
        self.torch = torch
    }

    var parameters: JSONSchema? {
        .object(
            description: "Flashlight parameters",
            properties: [
                "on": .boolean(description: "true to turn it on, false to turn it off"),
                "percent": .integer(description: "Optional brightness 1-100 when turning on"),
            ],
            required: ["on"]
        )
    }

    func execute(arguments: JSONValue) async throws -> String {
        guard let on = arguments["on"]?.boolValue else {
            throw ToolError.missingArgument("on")
        }
        let percent = arguments["percent"]?.intValue ?? 100
        guard (1...100).contains(percent) else {
            throw ToolError.invalidArgument("percent", expected: "1 to 100")
        }
        try await torch.setTorch(on: on, level: Double(percent) / 100)
        return on ? "Flashlight on." : "Flashlight off."
    }

    func risk(for arguments: JSONValue) -> RiskTier { .writePrivate }
    func describe(_ arguments: JSONValue) -> String {
        arguments["on"]?.boolValue == false ? "Turn the flashlight off" : "Turn the flashlight on"
    }
}

// MARK: Screen brightness

/// The screen's brightness. Injectable so the tool is testable without a screen.
protocol ScreenBrightnessControlling: Sendable {
    /// Sets the brightness, 0 to 1. Throws when there is no screen to set.
    func setBrightness(_ fraction: Double) async throws
}

#if os(iOS)
import UIKit

struct SystemScreenBrightness: ScreenBrightnessControlling {
    func setBrightness(_ fraction: Double) async throws {
        let done: Bool = await MainActor.run {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
            else { return false }
            scene.screen.brightness = CGFloat(min(max(fraction, 0), 1))
            return true
        }
        guard done else { throw ToolError.executionFailed("There is no screen to change right now.") }
    }
}
#endif

struct BrightnessTool: Tool {
    let name = "phone_brightness"
    let description = "Set the screen brightness to 'percent' (0-100). iOS may change it again with auto-brightness."

    let screen: any ScreenBrightnessControlling

    init(screen: any ScreenBrightnessControlling) {
        self.screen = screen
    }

    var parameters: JSONSchema? {
        .object(
            description: "Brightness parameters",
            properties: ["percent": .integer(description: "Brightness from 0 (dimmest) to 100 (brightest)")],
            required: ["percent"]
        )
    }

    func execute(arguments: JSONValue) async throws -> String {
        guard let percent = arguments["percent"]?.intValue else {
            throw ToolError.missingArgument("percent")
        }
        guard (0...100).contains(percent) else {
            throw ToolError.invalidArgument("percent", expected: "0 to 100")
        }
        try await screen.setBrightness(Double(percent) / 100)
        return "Brightness set to \(percent)%."
    }

    func risk(for arguments: JSONValue) -> RiskTier { .writePrivate }
    func describe(_ arguments: JSONValue) -> String {
        guard let percent = arguments["percent"]?.intValue else { return "Change the screen brightness" }
        return "Set the screen brightness to \(percent)%"
    }
}

// MARK: Apps by name

/// The apps Anu can open by name. iOS doesn't let an app list what's
/// installed, so this is a fixed list of each app's own link (URL scheme).
/// Names only, never a URL the model wrote, so a call can't be turned into an
/// arbitrary link; that's why these schemes don't need the allowlist.
enum PhoneApps {
    struct App: Equatable, Sendable {
        let name: String
        let url: String
        let aliases: [String]
    }

    static let all: [App] = [
        App(name: "Maps", url: "maps://", aliases: ["apple maps"]),
        App(name: "Music", url: "music://", aliases: ["apple music"]),
        App(name: "Podcasts", url: "podcasts://", aliases: []),
        App(name: "Calendar", url: "calshow://", aliases: []),
        App(name: "Photos", url: "photos-redirect://", aliases: []),
        App(name: "Mail", url: "message://", aliases: []),
        App(name: "Messages", url: "sms://", aliases: ["imessage"]),
        App(name: "FaceTime", url: "facetime://", aliases: []),
        App(name: "Notes", url: "mobilenotes://", aliases: []),
        App(name: "Reminders", url: "x-apple-reminderkit://", aliases: []),
        App(name: "Shortcuts", url: "shortcuts://", aliases: []),
        App(name: "App Store", url: "itms-apps://", aliases: ["appstore"]),
        App(name: "Books", url: "ibooks://", aliases: ["apple books"]),
        App(name: "Wallet", url: "shoebox://", aliases: ["apple wallet"]),
        App(name: "Spotify", url: "spotify://", aliases: []),
        App(name: "YouTube", url: "youtube://", aliases: []),
        App(name: "WhatsApp", url: "whatsapp://", aliases: []),
        App(name: "Instagram", url: "instagram://", aliases: []),
        App(name: "Gmail", url: "googlegmail://", aliases: []),
        App(name: "Google Maps", url: "comgooglemaps://", aliases: []),
        App(name: "Slack", url: "slack://", aliases: []),
        App(name: "Zoom", url: "zoomus://", aliases: []),
        App(name: "Uber", url: "uber://", aliases: []),
        App(name: "Netflix", url: "nflx://", aliases: []),
    ]

    /// The app a name means: its name or an alias, ignoring case, a leading
    /// "the"/"my" and a trailing "app". Nil when it isn't on the list.
    static func find(_ raw: String) -> App? {
        var name = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["the ", "my "] where name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        if name.hasSuffix(" app") { name.removeLast(4) }
        name = name.trimmingCharacters(in: .whitespaces)
        return all.first { $0.name.lowercased() == name || $0.aliases.contains(name) }
    }
}

struct OpenNamedAppTool: Tool {
    let name = "phone_open_app"
    let description = "Open an app on the phone by its name, such as 'Spotify', 'Maps' or 'Notes'."

    let opener: any URLOpening

    init(opener: any URLOpening) {
        self.opener = opener
    }

    var parameters: JSONSchema? {
        .object(
            description: "Open-app parameters",
            properties: ["name": .string(description: "The app's name, e.g. 'Spotify'")],
            required: ["name"]
        )
    }

    var sideEffect: ToolSideEffect { .external(capability: .appLaunch) }

    func execute(arguments: JSONValue) async throws -> String {
        guard let raw = ToolDescribing.text(arguments, "name") else { throw ToolError.missingArgument("name") }
        guard let app = PhoneApps.find(raw), let url = URL(string: app.url) else {
            let known = PhoneApps.all.map(\.name).joined(separator: ", ")
            throw ToolError.executionFailed("iPhone doesn't let Anu open \(ToolDescribing.quoted(raw)) by name. Apps it can open: \(known).")
        }
        await PrivacyLedger.shared.record(
            destination: .appLaunch(scheme: url.scheme ?? app.url, target: app.name),
            payload: url.absoluteString, redactions: 0)
        guard await opener.open(url) else {
            throw ToolError.executionFailed("Couldn't open \(app.name). It may not be installed.")
        }
        return "Opened \(app.name)."
    }

    /// Opening an app changes nothing for anyone else, and the user carries on
    /// there (Android: WRITE_PRIVATE). It asks once the turn is tainted.
    func risk(for arguments: JSONValue) -> RiskTier { .writePrivate }
    func describe(_ arguments: JSONValue) -> String {
        let raw = ToolDescribing.text(arguments, "name") ?? "an app"
        return "Open " + (PhoneApps.find(raw)?.name ?? raw)
    }
}

// MARK: Directions

struct NavigateTool: Tool {
    let name = "phone_navigate"
    let description = "Start directions to a place in Apple Maps. 'destination' is an address or place name; optional 'mode' driving, walking or transit."

    let appConfig: AppLauncherConfig
    let opener: any URLOpening

    init(appConfig: AppLauncherConfig, opener: any URLOpening) {
        self.appConfig = appConfig
        self.opener = opener
    }

    var parameters: JSONSchema? {
        .object(
            description: "Directions parameters",
            properties: [
                "destination": .string(description: "Address or place name"),
                "mode": .string(description: "driving, walking or transit", enumValues: ["driving", "walking", "transit"]),
            ],
            required: ["destination"]
        )
    }

    var sideEffect: ToolSideEffect { .external(capability: .appLaunch) }

    /// `maps://?daddr=…&dirflg=d`, Apple Maps' own link: it opens the Maps app
    /// on the phone rather than a web page.
    static func url(destination: String, mode: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "maps"
        components.host = ""
        let flag = ["walking": "w", "transit": "r"][mode ?? ""] ?? "d"
        components.queryItems = [URLQueryItem(name: "daddr", value: destination), URLQueryItem(name: "dirflg", value: flag)]
        return components.url
    }

    func execute(arguments: JSONValue) async throws -> String {
        guard let destination = ToolDescribing.text(arguments, "destination") else {
            throw ToolError.missingArgument("destination")
        }
        guard appConfig.allows(scheme: "maps") else {
            throw ToolError.executionFailed("The 'maps' scheme isn't in the allowed list. Add it in Settings → Connectors.")
        }
        guard let url = Self.url(destination: destination, mode: arguments["mode"]?.stringValue) else {
            throw ToolError.executionFailed("Couldn't build directions to \(ToolDescribing.quoted(destination)).")
        }
        await PrivacyLedger.shared.record(
            destination: .appLaunch(scheme: "maps", target: url.absoluteString),
            payload: url.absoluteString, redactions: 0)
        guard await opener.open(url) else {
            throw ToolError.executionFailed("Couldn't open Maps.")
        }
        return "Opened directions to \(destination) in Maps."
    }

    /// Android: WRITE_PRIVATE. Maps shows the route; the user starts it.
    func risk(for arguments: JSONValue) -> RiskTier { .writePrivate }
    func describe(_ arguments: JSONValue) -> String {
        "Directions to " + ToolDescribing.quoted(ToolDescribing.text(arguments, "destination") ?? "a place") + " in Maps"
    }
}

// MARK: Share sheet

/// Shows the system share sheet. Injectable so tests needn't present UI.
protocol SharePresenting: Sendable {
    /// Returns once the sheet is showing; false when there's nothing to show it on.
    func share(_ text: String) async -> Bool
}

#if os(iOS)
struct SystemSharePresenter: SharePresenting {
    func share(_ text: String) async -> Bool {
        await MainActor.run {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
                  var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController
                    ?? scene.windows.first?.rootViewController
            else { return false }
            while let presented = top.presentedViewController { top = presented }
            let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = top.view
            sheet.popoverPresentationController?.sourceRect = CGRect(
                x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            top.present(sheet, animated: true)
            return true
        }
    }
}
#endif

struct ShareTool: Tool {
    let name = "phone_share"
    let description = "Open the share sheet with some text, so the user can send it with any app."

    let presenter: any SharePresenting

    init(presenter: any SharePresenting) {
        self.presenter = presenter
    }

    var parameters: JSONSchema? {
        .object(
            description: "Share parameters",
            properties: ["text": .string(description: "The text to share")],
            required: ["text"]
        )
    }

    var sideEffect: ToolSideEffect { .external(capability: .appLaunch) }

    func execute(arguments: JSONValue) async throws -> String {
        guard let text = ToolDescribing.text(arguments, "text") else { throw ToolError.missingArgument("text") }
        await PrivacyLedger.shared.record(
            destination: .appLaunch(scheme: "share", target: "Share sheet"), payload: text, redactions: 0)
        guard await presenter.share(text) else {
            throw ToolError.executionFailed("Couldn't show the share sheet.")
        }
        return "Opened the share sheet with that text. Nothing is sent until you pick an app there."
    }

    /// Some share targets send or post on one tap, so this is approved as
    /// exactly this text every time (Android: WRITE_EXTERNAL, I2).
    func risk(for arguments: JSONValue) -> RiskTier { .writeExternal }
    func describe(_ arguments: JSONValue) -> String {
        "Share " + ToolDescribing.quoted(ToolDescribing.text(arguments, "text") ?? "")
    }
    func approvalNote(for arguments: JSONValue) -> String? {
        "The share sheet can send this with any app, some in one tap"
    }
    var editableFields: [EditableField] { [EditableField(key: "text", label: "Text", kind: .text)] }
}
