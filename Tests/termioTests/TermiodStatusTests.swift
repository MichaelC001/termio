import AppKit
import XCTest
@testable import termio

/// `TermioStore.applyTermiodStatus` — where a host-reported workstream state
/// becomes a row's status. The host names the state and this side decides what
/// it looks like, so these tests pin the *decisions*: which state settles as a
/// calm cue, which demands attention, and which is not the host's to make.
@MainActor
final class TermiodStatusTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // The attention arms ask whether the user is looking, which reads
        // `NSApp` — nil in a bare test process until something asks for the
        // shared application.
        _ = NSApplication.shared
    }

    private func makeStore(with session: Session) -> TermioStore {
        let workspace = Workspace(name: "Sessions")
        let project = Project(workspaceID: workspace.id, name: "termio", path: "/code/termio",
                              branch: "main", sessions: [session])
        let defaults = UserDefaults(suiteName: "termiod-status-\(UUID().uuidString)")
        return TermioStore(workspaces: [workspace], projects: [project],
                           settings: AppSettings(defaults: defaults ?? .standard))
    }

    private func status(_ state: String, title: String? = nil) -> Termiod.StatusPayload {
        Termiod.StatusPayload(session: "s_1", status: state, title: title)
    }

    /// A remote terminal is a plain `.terminal` row — the agent runs on the far
    /// machine. Gating on the local agent kind, as the hook path does, would
    /// discard every status a VPS agent reports, which is the entire reason this
    /// path exists.
    func testWorkingSpinsAPlainRemoteTerminalRow() {
        var session = Session(title: "ukvps", agent: .terminal)
        session.termiodRemoteHost = "ukvps"
        let store = makeStore(with: session)

        store.applyTermiodStatus(status("working"), for: session.id)

        XCTAssertEqual(store.status(for: session.id), .working)
    }

    func testDoneAndIdleSettleTheRow() {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(with: session)

        store.applyTermiodStatus(status("working"), for: session.id)
        store.applyTermiodStatus(status("done"), for: session.id)
        XCTAssertEqual(store.status(for: session.id), .done)

        store.applyTermiodStatus(status("idle"), for: session.id)
        XCTAssertEqual(store.status(for: session.id), .idle)
    }

    /// A failed run is not a green "ready for you" dot. It settles as attention
    /// the user can dismiss by looking, unlike a genuine blocking prompt.
    func testFailedAsksForAttentionRatherThanReadingAsSuccess() {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(with: session)

        store.applyTermiodStatus(status("working"), for: session.id)
        store.applyTermiodStatus(status("failed"), for: session.id)

        XCTAssertEqual(store.status(for: session.id), .needsAttention)
        XCTAssertFalse(store.blockingAttention.contains(session.id))
    }

    /// `needs_you` is an observable blocking condition, so its dot is recorded
    /// as blocking and survives a click — reading a permission prompt is not
    /// answering it.
    func testNeedsYouIsRecordedAsBlocking() {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(with: session)

        store.applyTermiodStatus(status("needs_you"), for: session.id)

        XCTAssertEqual(store.status(for: session.id), .needsAttention)
        XCTAssertTrue(store.blockingAttention.contains(session.id))
    }

    /// `unknown` is the daemon's default for a session nobody has reported on.
    /// Writing it would erase what the local signals worked out.
    func testUnknownLeavesTheRowAlone() {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(with: session)

        store.applyTermiodStatus(status("working"), for: session.id)
        store.applyTermiodStatus(status("unknown"), for: session.id)

        XCTAssertEqual(store.status(for: session.id), .working)
    }

    /// The workstream title is the agent's own label for the row, and lands in
    /// the same place the OSC 0/2 title does.
    func testTheWorkstreamTitleLandsOnTheRow() {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(with: session)

        store.applyTermiodStatus(status("working", title: "fix #164"), for: session.id)

        XCTAssertEqual(store.runtimes[session.id]?.liveTitle, "fix #164")
    }

    /// A report addressed to a session this app does not have is not this app's
    /// story — it must not mint a runtime for a row that isn't there.
    func testAReportForAnUnknownSessionIsDropped() {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(with: session)
        let stranger = UUID()

        store.applyTermiodStatus(status("working"), for: stranger)

        XCTAssertNil(store.runtimes[stranger])
    }

    // MARK: - Host-reported process facts

    /// Builds one roster row from the daemon's own JSON, with only the sampled
    /// fields the test cares about present — which is also how the wire looks,
    /// since the host omits what it could not answer.
    private func information(_ sampled: String, alive: Bool = true) throws
        -> Termiod.SessionInformation {
        let json = """
        {"id":"s_1","name":"demo","cwd":"/code/termio","command":"/bin/zsh -il","pid":4242,
         "rows":40,"cols":120,"clients":1,"created_unix":1786880000,"alive":\(alive),
         "status":"unknown","attached_clients":1\(sampled.isEmpty ? "" : ",\(sampled)")}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Termiod.SessionInformation.self, from: Data(json.utf8))
    }

    /// A session that answers to no folder — the only kind whose cwd is its own.
    private func makeLooseStore(with session: Session) -> TermioStore {
        var workspace = Workspace(name: "Sessions")
        workspace.terminals = [session]
        let defaults = UserDefaults(suiteName: "termiod-status-\(UUID().uuidString)")
        return TermioStore(workspaces: [workspace], projects: [],
                           settings: AppSettings(defaults: defaults ?? .standard))
    }

    /// A loose terminal owns its cwd, so the device's answer lands where the
    /// in-process kernel poll's answer lands.
    func testTheChildsDirectoryIsFollowedForALooseTerminal() throws {
        let session = Session(title: "ukvps", agent: .terminal)
        let store = makeLooseStore(with: session)

        store.applyTermiodInformation(
            try information(#""child_cwd":"/code/termio/web""#),
            for: session.id, identifiesAgent: true, followsWorkingDirectory: true)

        XCTAssertEqual(store.workingDirectory(for: session.id), "/code/termio/web")
    }

    /// A project session's place is its project, not wherever its shell wandered.
    /// The in-process poll reads no cwd for one of these at all, and the daemon
    /// path must not quietly start following one just because the host offers it.
    func testAProjectSessionsDirectoryIsNotFollowed() throws {
        let session = Session(title: "shell", agent: .terminal)
        let store = makeStore(with: session)

        store.applyTermiodInformation(
            try information(#""child_cwd":"/tmp/somewhere-else""#),
            for: session.id, identifiesAgent: true, followsWorkingDirectory: false)

        XCTAssertNil(store.workingDirectory(for: session.id))
    }

    /// A daemon that did not answer must not move the row. An absent directory
    /// is not "the shell is at `/`" — it is silence, and silence leaves the last
    /// known place alone.
    func testAnUnansweredDirectoryLeavesTheRowWhereItWas() throws {
        let session = Session(title: "ukvps", agent: .terminal)
        let store = makeLooseStore(with: session)
        store.noteWorkingDirectory("/code/termio", for: session.id)

        store.applyTermiodInformation(
            try information(#""foreground_pid":4242"#),
            for: session.id, identifiesAgent: true, followsWorkingDirectory: true)

        XCTAssertEqual(store.workingDirectory(for: session.id), "/code/termio")
    }

    /// An answered argv that matches no agent is the shell resurfacing: the
    /// hand-started agent exited, so the row stops being that agent.
    func testAShellResurfacingDemotesAPromotedRow() throws {
        var session = Session(title: "Claude Code", agent: .terminal)
        session.agent = AgentCatalog.shared.definition(for: "claude")
        let store = makeStore(with: session)

        store.applyTermiodInformation(
            try information(#""foreground_pid":4242,"foreground_argv":["-zsh"]"#),
            for: session.id, identifiesAgent: true, followsWorkingDirectory: false)

        XCTAssertEqual(store.session(session.id)?.agent, .terminal)
    }

    /// An *unanswered* argv is not a shell. An old daemon, or a process the
    /// kernel would not answer for, must never be read as "the agent is gone".
    func testAnUnansweredArgvNeverDemotesARow() throws {
        var session = Session(title: "Claude Code", agent: .terminal)
        session.agent = AgentCatalog.shared.definition(for: "claude")
        let store = makeStore(with: session)

        store.applyTermiodInformation(
            try information(#""child_cwd":"/code/termio""#),
            for: session.id, identifiesAgent: true, followsWorkingDirectory: false)

        XCTAssertEqual(store.session(session.id)?.agent.id, "claude")
    }

    /// A declared agent session never takes the identity half. Its foreground is
    /// whatever the agent spawned — a `rg`, a `git` — and reading that as "no
    /// agent here" would demote the row mid-turn. Mirrors where the in-process
    /// poll is installed: shell-backed rows only.
    func testADeclaredAgentSessionIsNotIdentifiedFromItsForeground() throws {
        var session = Session(title: "Claude Code", agent: .terminal)
        session.agent = AgentCatalog.shared.definition(for: "claude")
        let store = makeStore(with: session)

        store.applyTermiodInformation(
            try information(#""foreground_pid":9001,"foreground_argv":["rg","--json","TODO"]"#),
            for: session.id, identifiesAgent: false, followsWorkingDirectory: false)

        XCTAssertEqual(store.session(session.id)?.agent.id, "claude")
    }

    /// A row this app does not have is not this app's story — the push must not
    /// mint a runtime for it.
    func testAPushForAnUnknownSessionIsDropped() throws {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(with: session)
        let stranger = UUID()

        store.applyTermiodInformation(
            try information(#""child_cwd":"/code""#),
            for: stranger, identifiesAgent: true, followsWorkingDirectory: true)

        XCTAssertNil(store.runtimes[stranger])
    }

    // MARK: - Which producer answers "is a command running"

    /// The producer that owns the process wins, including when it says no: an
    /// in-process PTY is asked at the instant of the question, so its fresh
    /// `false` outranks a roster push sampled up to a poll ago.
    func testTheLocalPtyOutranksTheDevicesSample() {
        XCTAssertEqual(
            TermioStore.foregroundJob(reportedLocally: false, reportedByDevice: true), false)
        XCTAssertEqual(
            TermioStore.foregroundJob(reportedLocally: true, reportedByDevice: false), true)
    }

    /// A session this app does not host has only the device to ask.
    func testADaemonHostedSessionIsAnsweredByTheDevice() {
        XCTAssertEqual(
            TermioStore.foregroundJob(reportedLocally: nil, reportedByDevice: true), true)
        XCTAssertEqual(
            TermioStore.foregroundJob(reportedLocally: nil, reportedByDevice: false), false)
    }

    /// Nobody answering is not `false` — it is the absence the skew rule turns
    /// into today's no-confirm behaviour, one layer up.
    func testNobodyAnsweringStaysUnanswered() {
        XCTAssertNil(TermioStore.foregroundJob(reportedLocally: nil, reportedByDevice: nil))
    }

    /// Only an explicit `true` confirms. A shell with no producer at all — no PTY
    /// here, no link, which is every restored row before it is surfaced — closes
    /// without a dialog, and so does an agent row whichever way it answers.
    func testOnlyAnAnsweredJobEverConfirmsAClose() {
        let shell = Session(title: "shell", agent: .terminal)
        var agent = Session(title: "Claude Code", agent: .terminal)
        agent.agent = AgentCatalog.shared.definition(for: "claude")
        let store = makeStore(with: shell)

        XCTAssertNil(store.closeConfirmationReason(for: shell))
        XCTAssertNil(store.closeConfirmationReason(for: agent))
    }

    // MARK: - The exit policy both backends run

    /// A clean agent quit hands the pane back to a shell, and the same quit
    /// after the binary was replaced underneath it restarts the agent instead.
    /// One policy, whichever machine the PTY was on.
    func testACleanAgentQuitRevertsUnlessItsBinaryWasReplaced() {
        XCTAssertEqual(
            TermioStore.sessionExit(code: 0, isAgentSession: true, isPlainTerminal: false,
                                    executableReplaced: false),
            .revertToShell)
        XCTAssertEqual(
            TermioStore.sessionExit(code: 0, isAgentSession: true, isPlainTerminal: false,
                                    executableReplaced: true),
            .relaunch)
    }

    /// A plain terminal that exits cleanly closes its pane like a native terminal
    /// tab; an SSH terminal is one of those too, which is why the flags are
    /// separate rather than one being the negation of the other.
    func testACleanTerminalExitClosesThePane() {
        XCTAssertEqual(
            TermioStore.sessionExit(code: 0, isAgentSession: false, isPlainTerminal: true,
                                    executableReplaced: false),
            .close)
    }

    /// Anything non-zero stays on screen: its output is the only record of what
    /// went wrong, and closing or respawning over it loses that.
    func testANonZeroExitAlwaysParks() {
        for agent in [true, false] {
            for terminal in [true, false] {
                XCTAssertEqual(
                    TermioStore.sessionExit(code: 1, isAgentSession: agent,
                                            isPlainTerminal: terminal,
                                            executableReplaced: true),
                    .park)
            }
        }
    }

    // MARK: - The exit, wired

    private func agentSession() -> Session {
        var session = Session(title: "Claude Code", agent: .terminal)
        session.agent = AgentCatalog.shared.definition(for: "claude")
        return session
    }

    /// The wiring the whole exit row exists for: the device says the agent's
    /// binary was replaced under it, so the quit becomes the restart it asked
    /// for — the row keeps its identity and its process is respawned, rather than
    /// being handed back to a shell.
    func testAReplacedBinaryRelaunchesTheAgentInPlace() throws {
        let session = agentSession()
        let store = makeStore(with: session)
        store.setStatus(.working, for: session.id)

        store.applyTermiodExit(
            for: session.id, code: 0, runtimeMilliseconds: 90_000,
            information: try information(#""child_executable_replaced":true"#, alive: false),
            isAgentSession: true, isPlainTerminal: false, surface: nil)

        XCTAssertEqual(store.session(session.id)?.agent.id, "claude")
        XCTAssertEqual(store.status(for: session.id), .idle)
    }

    /// The same clean quit with the binary untouched is a plain `/quit`: the pane
    /// goes back to being a shell.
    func testAnUntouchedBinaryHandsThePaneBackToAShell() throws {
        let session = agentSession()
        let store = makeStore(with: session)

        store.applyTermiodExit(
            for: session.id, code: 0, runtimeMilliseconds: 90_000,
            information: try information("", alive: false),
            isAgentSession: true, isPlainTerminal: false, surface: nil)

        XCTAssertEqual(store.session(session.id)?.agent, .terminal)
    }

    /// A daemon too old to carry an exit row says nothing, and nothing must never
    /// respawn a process the user quit.
    func testAnExitWithNoRowFromTheDeviceRevertsRatherThanRelaunching() {
        let session = agentSession()
        let store = makeStore(with: session)

        store.applyTermiodExit(
            for: session.id, code: 0, runtimeMilliseconds: 90_000, information: nil,
            isAgentSession: true, isPlainTerminal: false, surface: nil)

        XCTAssertEqual(store.session(session.id)?.agent, .terminal)
    }

    /// A clean plain-terminal exit takes the pane with it, and the link goes with
    /// the row.
    func testACleanTerminalExitRemovesTheRow() throws {
        let session = Session(title: "shell", agent: .terminal)
        let store = makeStore(with: session)

        store.applyTermiodExit(
            for: session.id, code: 0, runtimeMilliseconds: 5_000,
            information: try information("", alive: false),
            isAgentSession: false, isPlainTerminal: true, surface: nil)

        XCTAssertNil(store.session(session.id))
    }

    /// A failure parks: the row stays exactly as it was, so its output is still
    /// on screen to read. Even with the replacement flag set — a non-zero exit is
    /// not the restart the agent asked for.
    func testAFailedExitLeavesTheRowStanding() throws {
        let session = agentSession()
        let store = makeStore(with: session)

        store.applyTermiodExit(
            for: session.id, code: 1, runtimeMilliseconds: 90_000,
            information: try information(#""child_executable_replaced":true"#, alive: false),
            isAgentSession: true, isPlainTerminal: false, surface: nil)

        XCTAssertEqual(store.session(session.id)?.agent.id, "claude")
    }

    // MARK: - Tombstones

    private func tombstone(name: String, reason: String) throws -> Termiod.SessionTombstone {
        let json = """
        {"id":"s_1","name":"\(name)","cwd":"/code","command":"claude","reason":"\(reason)",
         "created_unix":1786880000,"ended_unix":1786886075,"status":"working"}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Termiod.SessionTombstone.self, from: Data(json.utf8))
    }

    private func live(name: String) throws -> Termiod.SessionInformation {
        let json = """
        {"id":"s_1","name":"\(name)","pid":42,"alive":true,"cwd":"/code",
         "command":"claude","status":"working","agent_id":null,"title":null,
         "created_unix":1786880000,"attached_clients":1}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Termiod.SessionInformation.self, from: Data(json.utf8))
    }

    /// The reason a row's session died is addressable from the row.
    func testAnEndReasonIsFoundFromItsSession() throws {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(with: session)
        let name = session.id.uuidString

        store.recordTombstones(
            [try tombstone(name: name, reason: "daemon_lost")], live: [], persisted: [name])

        XCTAssertEqual(store.termiodEndReason(for: session)?.reason, "daemon_lost")
    }

    /// A name that comes back alive buries its own grave. Tombstones merge rather
    /// than replace, so without this a session restarted under the same name would
    /// keep wearing the end reason of the run before it.
    func testALiveNameLosesItsTombstone() throws {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(with: session)
        let name = session.id.uuidString

        store.recordTombstones(
            [try tombstone(name: name, reason: "daemon_lost")], live: [], persisted: [name])
        XCTAssertNotNil(store.termiodEndReason(for: session))

        store.recordTombstones([], live: [try live(name: name)], persisted: [name])
        XCTAssertNil(store.termiodEndReason(for: session))
    }

    /// Another client's sessions share the daemon but not the sidebar. Keeping
    /// their graves would put rows in this map that no row can ever ask about.
    func testTombstonesForOtherClientsSessionsAreNotKept() throws {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(with: session)

        store.recordTombstones(
            [try tombstone(name: "someone-elses-session", reason: "exited")],
            live: [], persisted: [session.id.uuidString])

        XCTAssertTrue(store.termiodTombstones.isEmpty)
        XCTAssertNil(store.termiodEndReason(for: session))
    }
}
