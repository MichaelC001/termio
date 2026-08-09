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
}
