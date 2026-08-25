import XCTest
@testable import termio

/// The one line every hook dialect embeds. A hook that names the wrong binary,
/// cannot name its session, or passes a flag the binary rejects fails silently
/// on every agent turn — which is indistinguishable from an agent that never
/// reported, so these are asserted rather than eyeballed.
final class HookReportCommandTests: XCTestCase {
    func testTheMacReportsThroughTheTermioCLI() {
        let command = AgentStatusHooks.reportCommand(state: "working")
        XCTAssertTrue(command.contains(" agent report working"))
        XCTAssertTrue(command.contains(AgentStatusHooks.cliMarker))
    }

    /// A device has no `termio` and no app to report to: its hooks talk to the
    /// daemon that owns their PTY, which broadcasts `E status` to every viewer.
    func testADeviceReportsThroughTheDaemon() {
        let command = AgentStatusHooks.reportCommand(state: "needs_you", reporter: .termiodDaemon)
        XCTAssertTrue(command.contains("set-status"))
        XCTAssertTrue(command.contains("\"$TERMIOD_SESSION_ID\" needs_you"))
        XCTAssertFalse(command.contains("agent report"))
    }

    /// `termiod set-status` takes an id, a state and an optional title, and
    /// nothing else. Emitting the stdin-mining flags there would make the remote
    /// binary reject the whole invocation.
    func testTheDaemonFormDropsTheStdinMiningFlags() {
        let command = AgentStatusHooks.reportCommand(
            state: "done", withTranscript: true, conversationField: "session_id",
            toolField: "tool_name", promptTitleField: "prompt", reporter: .termiodDaemon)
        for flag in ["--transcript", "--conversation-from", "--tool-from", "--prompt-title-from"] {
            XCTAssertFalse(command.contains(flag), "\(flag) has no counterpart in set-status")
        }
    }

    /// Cursor reads a hook's stdout as its JSON reply, so the device form owes it
    /// the same benign `{}` the local form prints.
    func testTheDaemonFormKeepsCursorsStdoutContract() {
        let command = AgentStatusHooks.reportCommand(
            state: "idle", dialect: .cursorFlat, reporter: .termiodDaemon)
        XCTAssertTrue(command.contains("printf '{}'"))
    }

    /// Quoting a manifest path for the remote shell must not quote away the
    /// tilde: `'~/.claude/settings.json'` would read and write a literal `~`
    /// directory beside the user's home, so every install would appear to work
    /// and no agent would ever load a hook.
    func testRemoteQuotingLeavesTheLeadingTildeExpandable() {
        XCTAssertEqual(
            SSHAgentConfigStore.quote("~/.claude/settings.json"),
            "\"$HOME\"/'.claude/settings.json'")
        XCTAssertEqual(SSHAgentConfigStore.quote("~"), "\"$HOME\"")
    }

    /// An absolute path, and a tilde that is not the first character, are
    /// ordinary text and stay fully quoted.
    func testRemoteQuotingStillQuotesEverythingElse() {
        XCTAssertEqual(SSHAgentConfigStore.quote("/etc/x"), "'/etc/x'")
        XCTAssertEqual(SSHAgentConfigStore.quote("/tmp/a~b"), "'/tmp/a~b'")
        XCTAssertEqual(SSHAgentConfigStore.quote("it's"), "'it'\\''s'")
    }

    /// The version comment is what makes the idempotent write re-install hooks on
    /// the first launch after an upgrade — it has to survive on both forms.
    func testBothFormsCarryTheVersionStamp() {
        for reporter in [HookReporter.termioCLI, .termiodDaemon] {
            let command = AgentStatusHooks.reportCommand(state: "idle", reporter: reporter)
            XCTAssertTrue(command.contains(AgentStatusHooks.hookVersionMarker))
        }
    }
}
