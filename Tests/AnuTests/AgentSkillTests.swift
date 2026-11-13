import XCTest
import CryptoKit
@testable import Anu

/// SKILL.md parsing and refusals, finding a skill by name, matching, and the
/// library's storage (ADR-120).
final class AgentSkillTests: XCTestCase {
    static let valid = """
    ---
    name: word-count
    description: "Counts the words in a text."
    homepage: https://example.com/word-count
    ---

    # Word count

    Call run_js with scripts/index.js.
    """

    // MARK: Parsing

    func testParsesFrontMatterAndBody() throws {
        let skill = try SkillMd.parse(Self.valid, origin: .builtIn)
        XCTAssertEqual(skill.name, "word-count")
        XCTAssertEqual(skill.description, "Counts the words in a text.", "surrounding quotes are removed")
        XCTAssertEqual(skill.homepage, "https://example.com/word-count")
        XCTAssertFalse(skill.requireSecret)
        XCTAssertTrue(skill.instructions.hasPrefix("# Word count"))
        XCTAssertTrue(skill.content.hasPrefix("---\nname: word-count"), "load_skill returns the whole file")
        XCTAssertFalse(skill.untrusted)
    }

    func testReadsRequireSecretAndCRLF() throws {
        let text = "---\r\nname: api-skill\r\ndescription: Uses a key\r\nrequire-secret: TRUE\r\n---\r\nDo it.\r\n"
        let skill = try SkillMd.parse(text, origin: .added)
        XCTAssertTrue(skill.requireSecret)
        XCTAssertEqual(skill.instructions, "Do it.")
        XCTAssertTrue(skill.untrusted)
    }

    func testRefusesMalformedSkillsWithAReason() {
        func reason(_ text: String) -> String? {
            do { _ = try SkillMd.parse(text, origin: .added); return nil } catch { return error.localizedDescription }
        }
        XCTAssertEqual(reason("name: x\ndescription: y\n"), "a SKILL.md starts with a --- line")
        XCTAssertEqual(reason("---\nname: x\ndescription: y\n"), "a SKILL.md's front matter ends with a --- line")
        XCTAssertEqual(reason("---\nname: QR Code\ndescription: y\n---\nbody"),
                       "a skill's name is lowercase words joined by hyphens, such as qr-text")
        XCTAssertEqual(reason("---\ndescription: y\n---\nbody"),
                       "a skill's name is lowercase words joined by hyphens, such as qr-text")
        XCTAssertEqual(reason("---\nname: ok-name\ndescription:\n---\nbody"), "the skill ok-name has no description")
        XCTAssertEqual(reason("---\nname: ok-name\ndescription: fine\n---\n  \n"),
                       "the skill ok-name has no instructions after its front matter")
        XCTAssertEqual(reason("---\nname: ../etc\ndescription: y\n---\nbody"),
                       "a skill's name is lowercase words joined by hyphens, such as qr-text",
                       "a name can't be a path")
        let huge = "---\nname: big\ndescription: y\n---\n" + String(repeating: "a", count: SkillMd.maxBytes)
        XCTAssertEqual(reason(huge), "a SKILL.md can be at most 100 KB")
    }

    func testFirstSpellingOfAKeyWinsAndDescriptionIsCapped() throws {
        let long = String(repeating: "d", count: 400)
        let skill = try SkillMd.parse("---\nname: first\nname: second\ndescription: \(long)\n---\nbody", origin: .added)
        XCTAssertEqual(skill.name, "first")
        XCTAssertEqual(skill.description.count, SkillMd.maxDescription)
    }

    // MARK: Finding and matching

    func testFindIgnoresCaseHyphensUnderscoresAndSpaces() throws {
        let catalog = StaticSkillCatalog(skills: [try SkillMd.parse(Self.valid, origin: .builtIn)])
        XCTAssertEqual(catalog.find("Word_Count")?.name, "word-count")
        XCTAssertEqual(catalog.find("word count")?.name, "word-count")
        XCTAssertEqual(catalog.find("wordcount")?.name, "word-count")
        XCTAssertNil(catalog.find("word-counter"))
        XCTAssertNil(catalog.find(""))
    }

    func testMatchingFindsSkillsByNameOrDescriptionWords() throws {
        let hash = try SkillMd.parse("---\nname: calculate-hash\ndescription: SHA-256 checksum of text\n---\nbody", origin: .builtIn)
        let count = try SkillMd.parse(Self.valid, origin: .builtIn)
        XCTAssertEqual(SkillMatch.matching("What's the sha of hello?", [hash, count]).map(\.name), ["calculate-hash"])
        XCTAssertEqual(SkillMatch.matching("how many words in this?", [hash, count]).map(\.name), ["word-count"])
        XCTAssertTrue(SkillMatch.matching("Hi, how are you today?", [hash, count]).isEmpty)
        XCTAssertTrue(SkillMatch.matching("", [hash, count]).isEmpty)
    }

    func testEveryBundledSkillParses() throws {
        // The test host is the app, so its bundle carries the Skills folder.
        let root = try XCTUnwrap(Bundle.main.url(forResource: "Skills", withExtension: nil), "Skills folder isn't bundled")
        let library = SkillLibrary(bundledRoot: root, addedRoot: Self.tempDir(), defaults: Self.defaults(),
                                   keys: Self.keys, recordEgress: { _, _ in })
        XCTAssertEqual(library.problems, [])
        XCTAssertEqual(Set(library.enabledSkills().map(\.name)),
                       ["calculate-hash", "email-draft", "unit-table", "word-count"])
        XCTAssertTrue(library.enabledSkills().allSatisfy { $0.origin == .builtIn })
        for skill in library.enabledSkills() where skill.name != "email-draft" {
            XCTAssertFalse(try library.script(for: skill, named: "index.js").isEmpty, skill.name)
        }
    }

    // MARK: Library

    static let keys = StaticDataKey(key: SymmetricKey(size: .bits256))

    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)", isDirectory: true)
    }

    static func defaults() -> UserDefaults {
        UserDefaults(suiteName: "skills-\(UUID().uuidString)")!
    }

    /// A bundled-skills folder on disk with the given SKILL.md texts.
    static func bundle(_ skills: [String: String]) throws -> URL {
        let root = tempDir()
        for (name, text) in skills {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        return root
    }

    func testBadBundledFolderIsLeftOutAndNamed() throws {
        let root = try Self.bundle(["word-count": Self.valid, "broken": "no front matter"])
        let library = SkillLibrary(bundledRoot: root, addedRoot: Self.tempDir(), defaults: Self.defaults(),
                                   keys: Self.keys, recordEgress: { _, _ in })
        XCTAssertEqual(library.enabledSkills().map(\.name), ["word-count"])
        XCTAssertEqual(library.problems, ["broken: a SKILL.md starts with a --- line"])
    }

    func testSwitchesHideASkillFromTheModel() throws {
        let library = SkillLibrary(bundledRoot: try Self.bundle(["word-count": Self.valid]), addedRoot: Self.tempDir(),
                                   defaults: Self.defaults(), keys: Self.keys, recordEgress: { _, _ in })
        library.setEnabled("word-count", false)
        XCTAssertTrue(library.enabledSkills().isEmpty)
        XCTAssertNil(library.find("word-count"), "a turned-off skill can't be loaded")
        XCTAssertEqual(library.entries().map(\.enabled), [false], "but the Skills page still lists it")
        library.setEnabled("word-count", true)
        XCTAssertEqual(library.enabledSkills().count, 1)
    }

    func testAddedSkillIsStoredEncryptedAndSurvivesReload() throws {
        let added = Self.tempDir()
        let defaults = Self.defaults()
        let library = SkillLibrary(bundledRoot: nil, addedRoot: added, defaults: defaults, keys: Self.keys, recordEgress: { _, _ in })
        let text = Self.valid.replacingOccurrences(of: "word-count", with: "my-count")
        try library.add(skillMd: text, scripts: ["index.js": "function run(d) { return d }"])

        let stored = added.appendingPathComponent("my-count/SKILL.md")
        XCTAssertTrue(SecureFile.isEncrypted(stored), "user-added skills go through SecureFile")
        XCTAssertTrue(SecureFile.isEncrypted(added.appendingPathComponent("my-count/scripts/index.js")))

        let again = SkillLibrary(bundledRoot: nil, addedRoot: added, defaults: defaults, keys: Self.keys, recordEgress: { _, _ in })
        let skill = try XCTUnwrap(again.find("my-count"))
        XCTAssertEqual(skill.origin, .added)
        XCTAssertEqual(try again.script(for: skill, named: "index"), "function run(d) { return d }")

        try again.delete("my-count")
        XCTAssertNil(again.find("my-count"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: added.appendingPathComponent("my-count").path))
    }

    func testAddedSkillCantTakeABuiltInName() throws {
        let library = SkillLibrary(bundledRoot: try Self.bundle(["word-count": Self.valid]), addedRoot: Self.tempDir(),
                                   defaults: Self.defaults(), keys: Self.keys, recordEgress: { _, _ in })
        XCTAssertThrowsError(try library.add(skillMd: Self.valid)) { error in
            XCTAssertEqual(error.localizedDescription, "a built-in skill is already called word-count")
        }
        XCTAssertThrowsError(try library.delete("word-count"), "built-in skills can only be turned off")
    }

    func testAddFromFolderCopiesSkillMdAndScriptsOnly() throws {
        let folder = Self.tempDir()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Self.valid.replacingOccurrences(of: "word-count", with: "folder-skill")
            .write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "function run(d) { return 'ok' }".write(to: folder.appendingPathComponent("scripts/index.js"), atomically: true, encoding: .utf8)
        try "<html>".write(to: folder.appendingPathComponent("scripts/page.html"), atomically: true, encoding: .utf8)

        let added = Self.tempDir()
        let library = SkillLibrary(bundledRoot: nil, addedRoot: added, defaults: Self.defaults(), keys: Self.keys, recordEgress: { _, _ in })
        let skill = try library.addFromFile(folder)
        XCTAssertEqual(skill.name, "folder-skill")
        XCTAssertEqual(try library.script(for: skill, named: "index.js"), "function run(d) { return 'ok' }")
        XCTAssertFalse(FileManager.default.fileExists(atPath: added.appendingPathComponent("folder-skill/scripts/page.html").path))

        // A lone SKILL.md works too, and a malformed one is refused with its reason.
        let lone = Self.tempDir().appendingPathExtension("md")
        try "---\nname: Bad\n---\n".write(to: lone, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try library.addFromFile(lone)) { error in
            XCTAssertEqual(error.localizedDescription, "a skill's name is lowercase words joined by hyphens, such as qr-text")
        }
    }

    func testScriptNamesAreChecked() throws {
        XCTAssertEqual(try SkillLibrary.scriptFileName(""), "index.js")
        XCTAssertEqual(try SkillLibrary.scriptFileName("index.html"), "index.js", "Gallery's page name means the script")
        XCTAssertEqual(try SkillLibrary.scriptFileName("scripts/calc"), "calc.js")
        XCTAssertThrowsError(try SkillLibrary.scriptFileName("../SKILL.md"))
        XCTAssertThrowsError(try SkillLibrary.scriptFileName("a/b.js"))
    }

    func testFolderAddressesAndReferencedScripts() throws {
        XCTAssertEqual(try SkillLibrary.folderURL("https://example.com/skills/x/SKILL.md").absoluteString, "https://example.com/skills/x")
        XCTAssertEqual(try SkillLibrary.folderURL(" https://example.com/skills/x/ ").absoluteString, "https://example.com/skills/x")
        XCTAssertThrowsError(try SkillLibrary.folderURL("http://example.com/x")) { error in
            XCTAssertEqual(error.localizedDescription, "a skill's address must start with https://")
        }
        XCTAssertThrowsError(try SkillLibrary.folderURL("not a url"))
        XCTAssertEqual(SkillLibrary.referencedScripts(in: "run scripts/index.html then scripts/b.js and scripts/index.js"),
                       ["index.js", "b.js"])
    }
}
