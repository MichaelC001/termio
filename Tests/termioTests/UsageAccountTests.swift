import XCTest
@testable import termio

/// A second Claude Code account is a second `CLAUDE_CONFIG_DIR`, and its login
/// lives in a Keychain item whose name is derived from that folder. A wrong
/// derivation fails silently — the account just shows no plan limits — so the
/// rule is pinned here against a vector other readers of the same item agree on.
final class UsageAccountTests: XCTestCase {
    func testMovedClaudeHomeHashesIntoTheKeychainService() {
        let provider = ClaudeUsageProvider(home: URL(fileURLWithPath: "/Users/u/.claude-work"))
        XCTAssertEqual(provider.keychainService, "Claude Code-credentials-87169a1d")
    }

    func testUnmovedClaudeHomeKeepsTheLegacyKeychainService() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] != nil)
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        XCTAssertEqual(ClaudeUsageProvider(home: home).keychainService, "Claude Code-credentials")
    }

    /// The login must run with the folder exported exactly as `keychainService`
    /// hashes it, quoted so a space can't split it, and into a folder that
    /// exists — Codex refuses a missing `CODEX_HOME`.
    @MainActor
    func testSignInCommandExportsTheQuotedFolderAndCreatesIt() throws {
        let suite = "UsageAccountTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = UsageMonitor(settings: AppSettings(defaults: defaults))
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage account \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        let account = UsageAccount(agent: .claudeCode, home: home, isDefault: false)
        XCTAssertEqual(
            monitor.signInCommand(for: account),
            "export CLAUDE_CONFIG_DIR='\(home.path)'; claude auth login")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.path))
    }

    /// A session on an extra account resumes from that account's folder; one on
    /// the default account, or a path outside the config home, is untouched.
    func testManifestPathsMoveIntoTheAccountFolder() {
        let claude = AgentPreset.claudeCode
        XCTAssertEqual(
            claude.path("~/.claude/projects", inAccount: "/Users/u/.claude-2"),
            "/Users/u/.claude-2/projects")
        XCTAssertEqual(claude.path("~/.claude/projects", inAccount: nil), "~/.claude/projects")
        XCTAssertEqual(
            claude.path("~/.claudex/projects", inAccount: "/Users/u/.claude-2"),
            "~/.claudex/projects")
    }

    /// New sessions must never launch into a folder that is no longer an
    /// account: removing it, or deleting it on disk, falls back to the default.
    @MainActor
    func testActiveAccountFallsBackToTheDefaultWhenItsFolderGoes() throws {
        let suite = "UsageAccountTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-active-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        settings.addUsageAccountFolder(folder.path, for: .claudeCode)
        settings.setActiveAccountFolder(folder.path, for: .claudeCode)
        XCTAssertEqual(settings.activeAccountFolder(for: .claudeCode), folder.path)

        try FileManager.default.removeItem(at: folder)
        XCTAssertNil(settings.activeAccountFolder(for: .claudeCode))

        settings.removeUsageAccountFolder(folder.path, for: .claudeCode)
        XCTAssertNil(settings.usageActiveAccounts[AgentPreset.claudeCode.rawValue])
    }

    /// The export must cover the whole authored line, or `prepare && claude`
    /// runs the agent on the default account.
    @MainActor
    func testAccountExportCoversACompoundCommand() {
        XCTAssertEqual(
            TermioStore.exporting("CODEX_HOME", "/Users/u/.codex-2", before: "prepare && codex"),
            "export CODEX_HOME='/Users/u/.codex-2'; prepare && codex")
    }

    /// Only folders termiod will install hooks into may be added by hand.
    @MainActor
    func testAccountFoldersMustSitBesideTheDefaultFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let named = { (name: String) in home.appendingPathComponent(name) }
        XCTAssertTrue(UsageMonitor.isAccountFolder(named(".codex-work"), for: .codex))
        XCTAssertFalse(UsageMonitor.isAccountFolder(named(".codex"), for: .codex))
        XCTAssertFalse(UsageMonitor.isAccountFolder(named(".codexwork"), for: .codex))
        XCTAssertFalse(UsageMonitor.isAccountFolder(named("work/.codex-2"), for: .codex))
    }

    func testAccountTotalsSumAcrossFolders() {
        let day = Date(timeIntervalSince1970: 0)
        var first = AgentTokenUsage()
        first.today = TokenWindowStats(input: 10)
        first.daily[day] = TokenWindowStats(input: 10)
        var second = AgentTokenUsage(hasCost: true)
        second.today = TokenWindowStats(output: 5)
        second.daily[day] = TokenWindowStats(output: 5)

        first.add(second)
        XCTAssertEqual(first.today.total, 15)
        XCTAssertEqual(first.daily[day]?.total, 15)
        XCTAssertTrue(first.hasCost)
    }
}
