import Foundation
import os

/// A skill as the Skills page lists it: on or off.
struct SkillEntry: Identifiable, Sendable, Equatable {
    let skill: AgentSkill
    let enabled: Bool
    var id: String { skill.name }
}

/// The app's Agent Skills (Anu Android `SkillLibrary`, ADR-120): the built-in
/// ones in the app bundle's `Skills` folder, and those the user added from a
/// file or a web address, stored encrypted under Application Support. A skill
/// added from the web is downloaded once — its `SKILL.md` and the scripts it
/// names — and runs from the stored copy, never from the web. Any skill can be
/// turned off.
///
/// Thread-safe: tools read it off the main actor.
final class SkillLibrary: SkillCatalog, @unchecked Sendable {
    static let shared = SkillLibrary()

    /// Records a download in the privacy ledger. Injected so tests can see it.
    typealias EgressRecorder = @Sendable (_ destination: EgressDestination, _ payload: String) async -> Void

    static let scriptsFolder = "scripts"
    static let maxScriptBytes = 200_000
    static let maxScripts = 8
    private static let sourceFile = ".source"
    private static let disabledKey = "skills_disabled"

    private struct State {
        var builtIn: [AgentSkill] = []
        var added: [AgentSkill] = []
        var problems: [String] = []
    }

    private let bundledRoot: URL?
    private let addedRoot: URL
    private let defaults: UserDefaults
    private let keys: DataKeyProviding
    private let session: URLSession
    private let recordEgress: EgressRecorder
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        bundledRoot: URL? = Bundle.main.url(forResource: "Skills", withExtension: nil),
        addedRoot: URL = SkillLibrary.defaultAddedRoot,
        defaults: UserDefaults = .standard,
        keys: DataKeyProviding = KeychainDataKey.shared,
        session: URLSession = .shared,
        recordEgress: @escaping EgressRecorder = { destination, payload in
            await PrivacyLedger.shared.record(destination: destination, payload: payload, redactions: 0)
        }
    ) {
        self.bundledRoot = bundledRoot
        self.addedRoot = addedRoot
        self.defaults = defaults
        self.keys = keys
        self.session = session
        self.recordEgress = recordEgress
        reload()
    }

    static var defaultAddedRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Skills", isDirectory: true)
    }

    // MARK: - Reading

    func enabledSkills() -> [AgentSkill] {
        let off = disabled()
        return all().filter { !off.contains($0.name) }
    }

    /// Every skill with its switch, built-in first, for the Skills page.
    func entries() -> [SkillEntry] {
        let off = disabled()
        return all().map { SkillEntry(skill: $0, enabled: !off.contains($0.name)) }
    }

    /// Folders that were left out because they aren't valid skills, with why.
    var problems: [String] { state.withLock { $0.problems } }

    private func all() -> [AgentSkill] {
        state.withLock { $0.builtIn + $0.added }
    }

    /// Reads the built-in and added skills again. A folder that isn't a valid
    /// skill is left out and named in `problems`.
    func reload() {
        var problems: [String] = []
        var builtIn: [AgentSkill] = []
        for dir in subfolders(of: bundledRoot) {
            do {
                let text = try String(contentsOf: dir.appendingPathComponent(SkillMd.fileName), encoding: .utf8)
                builtIn.append(try SkillMd.parse(text, origin: .builtIn))
            } catch {
                problems.append("\(dir.lastPathComponent): \(error.localizedDescription)")
            }
        }
        var added: [AgentSkill] = []
        for dir in subfolders(of: addedRoot) {
            do {
                guard let data = SecureFile.read(dir.appendingPathComponent(SkillMd.fileName), keys: keys),
                      let text = String(data: data, encoding: .utf8) else {
                    throw SkillParseError("its SKILL.md can't be read")
                }
                let source = SecureFile.read(dir.appendingPathComponent(Self.sourceFile), keys: keys)
                    .flatMap { String(data: $0, encoding: .utf8) }
                let skill = try SkillMd.parse(text, origin: .added, source: source)
                // An added skill can't take a built-in one's name.
                guard !builtIn.contains(where: { $0.name == skill.name }) else { continue }
                added.append(skill)
            } catch {
                problems.append("\(dir.lastPathComponent): \(error.localizedDescription)")
            }
        }
        builtIn.sort { $0.name < $1.name }
        added.sort { $0.name < $1.name }
        state.withLock { $0 = State(builtIn: builtIn, added: added, problems: problems) }
    }

    /// The text of one of `skill`'s scripts. `name` may be `index`, `index.js`
    /// or `scripts/index.js`; a Gallery-style `index.html` means `index.js`.
    func script(for skill: AgentSkill, named name: String) throws -> String {
        let file = try Self.scriptFileName(name)
        switch skill.origin {
        case .builtIn:
            guard let dir = bundledRoot?.appendingPathComponent(skill.name, isDirectory: true) else { break }
            let url = dir.appendingPathComponent(Self.scriptsFolder).appendingPathComponent(file)
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        case .added:
            let url = addedRoot.appendingPathComponent(skill.name, isDirectory: true)
                .appendingPathComponent(Self.scriptsFolder).appendingPathComponent(file)
            if let data = SecureFile.read(url, keys: keys), let text = String(data: data, encoding: .utf8) { return text }
        }
        throw SkillParseError("the \(skill.name) skill has no script \(Self.scriptsFolder)/\(file)")
    }

    /// A script's file name, checked: letters, digits, `-` and `_`, ending `.js`.
    static func scriptFileName(_ raw: String) throws -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "index.js" }
        if name.hasPrefix(scriptsFolder + "/") { name.removeFirst(scriptsFolder.count + 1) }
        if name.hasSuffix(".html") { name = String(name.dropLast(5)) + ".js" }
        if !name.hasSuffix(".js") { name += ".js" }
        let stem = name.dropLast(3)
        guard !stem.isEmpty, stem.count <= 64,
              stem.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw SkillParseError("“\(raw)” isn't one of the skill's scripts")
        }
        return name
    }

    // MARK: - Switches

    func setEnabled(_ name: String, _ on: Bool) {
        var off = disabled()
        if on { off.remove(name) } else { off.insert(name) }
        defaults.set(Array(off).sorted(), forKey: Self.disabledKey)
    }

    private func disabled() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
    }

    // MARK: - Adding

    /// Adds a skill from its `SKILL.md` text and its scripts (file name →
    /// source). Replaces an added skill of the same name; refuses a built-in's.
    @discardableResult
    func add(skillMd text: String, scripts: [String: String] = [:], source: String? = nil) throws -> AgentSkill {
        let skill = try SkillMd.parse(text, origin: .added, source: source)
        guard !state.withLock({ $0.builtIn.contains { $0.name == skill.name } }) else {
            throw SkillParseError("a built-in skill is already called \(skill.name)")
        }
        guard scripts.count <= Self.maxScripts else {
            throw SkillParseError("a skill can have at most \(Self.maxScripts) scripts")
        }
        var checked: [String: Data] = [:]
        for (raw, body) in scripts {
            let file = try Self.scriptFileName(raw)
            let data = Data(body.utf8)
            guard data.count <= Self.maxScriptBytes else {
                throw SkillParseError("the script \(file) is larger than \(Self.maxScriptBytes / 1000) KB")
            }
            checked[file] = data
        }

        let dir = addedRoot.appendingPathComponent(skill.name, isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        do {
            try SecureFile.write(Data(text.utf8), to: dir.appendingPathComponent(SkillMd.fileName), keys: keys)
            if let source {
                try SecureFile.write(Data(source.utf8), to: dir.appendingPathComponent(Self.sourceFile), keys: keys)
            }
            for (file, data) in checked {
                let url = dir.appendingPathComponent(Self.scriptsFolder, isDirectory: true).appendingPathComponent(file)
                try SecureFile.write(data, to: url, keys: keys)
            }
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
        reload()
        return skill
    }

    /// Adds a skill the user picked in Files: a `SKILL.md` on its own, or a
    /// skill folder (its `SKILL.md` and `scripts/*.js`; anything else is left).
    @discardableResult
    func addFromFile(_ url: URL) throws -> AgentSkill {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw SkillParseError("that file can't be opened")
        }
        let md = isDir.boolValue ? url.appendingPathComponent(SkillMd.fileName) : url
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: md.path) else {
            throw SkillParseError("that folder has no SKILL.md")
        }
        guard (attributes[.size] as? Int ?? 0) <= SkillMd.maxBytes else {
            throw SkillParseError("a SKILL.md can be at most \(SkillMd.maxBytes / 1000) KB")
        }
        guard let text = try? String(contentsOf: md, encoding: .utf8) else {
            throw SkillParseError("that SKILL.md isn't UTF-8 text")
        }
        var scripts: [String: String] = [:]
        if isDir.boolValue {
            let folder = url.appendingPathComponent(Self.scriptsFolder, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for file in files where file.pathExtension == "js" {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= Self.maxScriptBytes else {
                    throw SkillParseError("the script \(file.lastPathComponent) is larger than \(Self.maxScriptBytes / 1000) KB")
                }
                scripts[file.lastPathComponent] = try String(contentsOf: file, encoding: .utf8)
            }
        }
        return try add(skillMd: text, scripts: scripts)
    }

    /// Adds the skill at a web address the user typed, as Gallery does: it reads
    /// `<address>/SKILL.md` (or the `SKILL.md` address itself), then the scripts
    /// the instructions name (`scripts/<name>.js`). Downloaded once and stored;
    /// every request is written to the privacy ledger first.
    @discardableResult
    func addFromURL(_ address: String) async throws -> AgentSkill {
        let folder = try Self.folderURL(address)
        let mdURL = folder.appendingPathComponent(SkillMd.fileName)
        let text = try await download(mdURL, limit: SkillMd.maxBytes, what: "SKILL.md")
        // Refuse a malformed skill before fetching anything else.
        let probe = try SkillMd.parse(text, origin: .added)

        var scripts: [String: String] = [:]
        let named = Self.referencedScripts(in: probe.content)
        guard named.count <= Self.maxScripts else {
            throw SkillParseError("a skill can have at most \(Self.maxScripts) scripts")
        }
        for file in named {
            let url = folder.appendingPathComponent(Self.scriptsFolder).appendingPathComponent(file)
            scripts[file] = try await download(url, limit: Self.maxScriptBytes, what: "\(Self.scriptsFolder)/\(file)")
        }
        return try add(skillMd: text, scripts: scripts, source: folder.absoluteString)
    }

    /// The skill folder an address names. Only https.
    static func folderURL(_ address: String) throws -> URL {
        var trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasSuffix("/" + SkillMd.fileName.lowercased()) {
            trimmed = String(trimmed.dropLast(SkillMd.fileName.count + 1))
        }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), url.host?.isEmpty == false else {
            throw SkillParseError("“\(address)” isn't a web address")
        }
        guard scheme == "https" else { throw SkillParseError("a skill's address must start with https://") }
        return url
    }

    /// `scripts/<name>.js` mentioned in a skill's text, in order of first mention.
    static func referencedScripts(in content: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "scripts/([A-Za-z0-9_-]{1,64})\\.(?:js|html)") // swiftlint:disable:this force_try
        var seen: [String] = []
        let range = NSRange(content.startIndex..., in: content)
        for match in pattern.matches(in: content, range: range) {
            guard let r = Range(match.range(at: 1), in: content) else { continue }
            let file = String(content[r]) + ".js"
            if !seen.contains(file) { seen.append(file) }
        }
        return seen
    }

    private func download(_ url: URL, limit: Int, what: String) async throws -> String {
        await recordEgress(.restHost(name: "Skill download", host: url.host ?? url.absoluteString), url.absoluteString)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SkillParseError("no answer from \(url.host ?? "that address")")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SkillParseError("couldn't download \(what) (HTTP \(http.statusCode))")
        }
        // A redirect may only stay on https.
        if let final = http.url, final.scheme?.lowercased() != "https" {
            throw SkillParseError("\(what) was redirected away from https")
        }
        guard data.count <= limit else { throw SkillParseError("\(what) is larger than \(limit / 1000) KB") }
        guard let text = String(data: data, encoding: .utf8) else { throw SkillParseError("\(what) isn't UTF-8 text") }
        return text
    }

    // MARK: - Deleting

    /// Deletes an added skill. Built-in skills can only be turned off.
    func delete(_ name: String) throws {
        guard let skill = all().first(where: { $0.name == name }) else { return }
        guard skill.origin == .added else {
            throw SkillParseError("\(name) is built in; turn it off instead")
        }
        try FileManager.default.removeItem(at: addedRoot.appendingPathComponent(name, isDirectory: true))
        setEnabled(name, true)
        reload()
    }

    // MARK: - Helpers

    private func subfolders(of root: URL?) -> [URL] {
        guard let root else { return [] }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
