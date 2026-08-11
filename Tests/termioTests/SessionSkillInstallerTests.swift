import XCTest
@testable import termio

/// The termio skill exists in three places: the app's bundled resource
/// (`Sources/termio/Resources/skills/termio/SKILL.md`, what
/// `SessionSkillInstaller` writes into each agent's skills directory), the
/// repo-root `skills/termio/SKILL.md` (the layout `npx skills add` and
/// `gh skill` discover for installs straight from GitHub), and the published
/// copy at `web/landing/public/skill.md` (https://termio.sh/skill.md). Nothing
/// at runtime ties them together, so this is the only thing that stops an edit
/// to one from silently drifting the others.
final class SessionSkillInstallerTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // termioTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    func testPublishedSkillMatchesInstalledSkill() throws {
        let source = repoRoot.appendingPathComponent(
            "Sources/termio/Resources/skills/termio/SKILL.md")
        let canonical = try String(contentsOf: source, encoding: .utf8)
        for mirror in ["skills/termio/SKILL.md", "web/landing/public/skill.md"] {
            XCTAssertEqual(
                try String(contentsOf: repoRoot.appendingPathComponent(mirror), encoding: .utf8),
                canonical,
                "\(mirror) must stay identical to the skill the app installs — update all copies together"
            )
        }
    }

    /// Exercises the resource-bundle lookup the installer relies on: a wrong
    /// `.copy` path or a renamed file would otherwise only surface as a silent
    /// per-target install failure at launch.
    func testBundledSkillResolves() throws {
        let skill = try XCTUnwrap(SessionSkillInstaller.skill)
        XCTAssertTrue(skill.hasPrefix("---\nname: termio\n"))
        XCTAssertTrue(skill.hasSuffix("\n"))
    }

    /// A manifest's `skills.dir` is the declaration the installer trusts — a user
    /// dropping a custom agent into `~/.termio/config/agents/` gets its skill
    /// installed through the same field, no code change.
    func testManifestSkillsDeclaresDirectory() throws {
        let json = """
        { "id": "custom", "name": "Custom", "skills": { "dir": "~/.custom/skills" } }
        """
        let manifest = try JSONDecoder().decode(AgentManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.skills?.dir, "~/.custom/skills")
    }

    /// A declared skills directory resolves to `<dir>/termio/SKILL.md` with `~`
    /// expanded — the only pure logic between the manifest and the file system.
    func testSkillFileURLExpandsTilde() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let url = SessionSkillInstaller.skillFileURL(directory: "~/custom/skills")
        XCTAssertEqual(url.lastPathComponent, "SKILL.md")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "termio")
        XCTAssertTrue(url.path.hasPrefix(home + "/custom/skills/termio/"))
    }

    /// The bundled manifests drive the installed surface: every skills-capable agent
    /// declares its directory, and agents whose ecosystem isn't confirmed stay
    /// undeclared so no stray directory gets created for them.
    func testBundledSkillDeclarationsMatchCatalog() throws {
        let catalog = AgentCatalog.shared
        let declared = Set(catalog.bundled.compactMap(\.skillDir))
        for directory in [
            "~/.claude/skills", "~/.codex/skills", "~/.cursor/skills",
            "~/.grok/skills", "~/.config/opencode/skills", "~/.pi/agent/skills",
        ] {
            XCTAssertTrue(declared.contains(directory), "\(directory) is missing from the bundled manifests")
        }
        for id in ["amp", "antigravity", "hermes", "kimi"] {
            XCTAssertNil(catalog.definition(for: id).skillDir, "\(id) must not declare skills yet")
        }
    }
}
