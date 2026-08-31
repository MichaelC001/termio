import XCTest
import TermioShared
@testable import termio

/// The wrapped-tree exit detector (RFC 20260830 §D2), as pure verdict logic —
/// the same shape as `StallProbeTests`: sequences of foreground samples in,
/// exactly one demotion out.
///
/// The scenario is #528's process tree: `zsh -ilc "exec claude"` where the
/// `exec` didn't replace the shell (an alias or function shim is enough), so
/// the agent quitting leaves the daemon session alive and no exit event ever
/// fires. The foreground sampler reporting the login shell is the only signal
/// left, and these pin how much of it counts as evidence.
final class AgentExitStreakTests: XCTestCase {
    func testTwoShellSamplesDemote() {
        var streak = AgentExitStreak()
        XCTAssertEqual(streak.observe(foregroundArgv: ["-zsh"]), .hold,
                       "one sample is a coincidence, not an exit")
        XCTAssertEqual(streak.observe(foregroundArgv: ["-zsh"]), .demote)
    }

    func testTheAgentInFrontResetsTheStreak() {
        var streak = AgentExitStreak()
        XCTAssertEqual(streak.observe(foregroundArgv: ["-zsh"]), .hold)
        XCTAssertEqual(streak.observe(foregroundArgv: ["claude"]), .hold)
        XCTAssertEqual(streak.observe(foregroundArgv: ["-zsh"]), .hold,
                       "the reset means the evidence starts over")
        XCTAssertEqual(streak.observe(foregroundArgv: ["-zsh"]), .demote)
    }

    /// `nil` argv is *unanswered* — a daemon too old to sample and an unreadable
    /// process look identical — so it must neither advance nor reset the streak.
    func testAnUnansweredSampleStandsDown() {
        var streak = AgentExitStreak()
        XCTAssertEqual(streak.observe(foregroundArgv: ["-zsh"]), .hold)
        XCTAssertEqual(streak.observe(foregroundArgv: nil), .hold)
        XCTAssertEqual(streak.observe(foregroundArgv: ["-zsh"]), .demote,
                       "an unanswered sample erased evidence it never contradicted")
    }

    func testDemotionFiresExactlyOnce() {
        var streak = AgentExitStreak()
        _ = streak.observe(foregroundArgv: ["-zsh"])
        XCTAssertEqual(streak.observe(foregroundArgv: ["-zsh"]), .demote)
        XCTAssertEqual(streak.observe(foregroundArgv: ["-zsh"]), .hold,
                       "a shell that stays in front must not re-fire every sample")
    }

    func testSomethingElseTakingTheForegroundBackClearsTheNotice() {
        var streak = AgentExitStreak()
        _ = streak.observe(foregroundArgv: ["-zsh"])
        _ = streak.observe(foregroundArgv: ["-zsh"])
        XCTAssertEqual(streak.observe(foregroundArgv: ["claude"]), .agentReturned)
        XCTAssertEqual(streak.observe(foregroundArgv: ["claude"]), .hold,
                       "the return is an edge, not a level")
    }

    func testShellRecognitionNormalizesLikeTheAgentCatalog() {
        XCTAssertTrue(AgentExitStreak.isShell(["-zsh"]), "login-shell marker")
        XCTAssertTrue(AgentExitStreak.isShell(["/bin/bash", "-il"]), "full path")
        XCTAssertTrue(AgentExitStreak.isShell(["fish"]))
        XCTAssertFalse(AgentExitStreak.isShell(["claude"]))
        XCTAssertFalse(AgentExitStreak.isShell(["vim", "notes.md"]))
        XCTAssertFalse(AgentExitStreak.isShell([]))
    }
}

/// The roster sweep's verdict for a session no row accounts for (RFC 20260830
/// §D3), and the path containment its project filing rests on.
final class ExternalSessionResolutionTests: XCTestCase {
    func testAJournaledNameIsKilledOnSight() {
        XCTAssertEqual(
            TermioStore.resolveExternalSession(
                name: "orphan", attachedClients: 0, isLocal: true, journaledNames: ["orphan"]),
            .killOnSight)
    }

    /// The journal outranks an attached client: a journaled name is this app's
    /// own closed session, and the close already promised it would end.
    func testTheJournalOutranksAnAttachedClient() {
        XCTAssertEqual(
            TermioStore.resolveExternalSession(
                name: "orphan", attachedClients: 1, isLocal: true, journaledNames: ["orphan"]),
            .killOnSight)
    }

    /// The local socket is per-uid, so an attached unknown on this Mac is a
    /// second install's live session — the one place attachment proves
    /// foreign ownership.
    func testAnAttachedStrangerIsLeftAloneOnThisMac() {
        XCTAssertEqual(
            TermioStore.resolveExternalSession(
                name: "theirs", attachedClients: 1, isLocal: true, journaledNames: []),
            .leaveAlone)
    }

    /// On a remote device the roster is that box's whole sidebar, and
    /// attachment is read-many by design — a session the phone has open is
    /// still one of the box's own sessions, so it gets a row like any other.
    func testAnAttachedStrangerIsAdoptedOnARemoteDevice() {
        XCTAssertEqual(
            TermioStore.resolveExternalSession(
                name: "phones", attachedClients: 1, isLocal: false, journaledNames: []),
            .adopt)
    }

    func testADetachedStrangerIsAdopted() {
        XCTAssertEqual(
            TermioStore.resolveExternalSession(
                name: "cli-started", attachedClients: 0, isLocal: true, journaledNames: []),
            .adopt)
    }

    func testPathContainmentIsByWholeComponents() {
        XCTAssertTrue(TermioStore.path("/code/termio", isInside: "/code/termio"))
        XCTAssertTrue(TermioStore.path("/code/termio/Sources/termio", isInside: "/code/termio"))
        XCTAssertFalse(TermioStore.path("/code/termio-worktrees/x", isInside: "/code/termio"),
                       "a sibling sharing a string prefix is not inside")
        XCTAssertFalse(TermioStore.path("/code", isInside: "/code/termio"))
        XCTAssertFalse(TermioStore.path("", isInside: "/code/termio"))
        XCTAssertFalse(TermioStore.path("/code/termio", isInside: ""))
    }
}

/// The sweep run against a real store: what one roster refresh does to rows,
/// the journal, and the tree. No daemon — the roster rows are decoded from the
/// wire shape, which is also the only way to construct them from here.
@MainActor
final class ExternalSessionSweepTests: XCTestCase {
    private func makeStore(projectPath: String = "/code/termio")
        -> (TermioStore, Workspace, Project) {
        let workspace = Workspace(name: "Sessions")
        let project = Project(workspaceID: workspace.id, name: "termio", path: projectPath,
                              branch: "main", sessions: [])
        let defaults = UserDefaults(suiteName: "sweep-\(UUID().uuidString)")
        let store = TermioStore(workspaces: [workspace], projects: [project],
                                settings: AppSettings(defaults: defaults ?? .standard))
        return (store, workspace, project)
    }

    private func information(
        name: String, cwd: String = "", attached: Int = 0
    ) throws -> Termiod.SessionInformation {
        let json = """
        {"id": "\(name)-id", "name": "\(name)", "pid": 1, "alive": true,
         "cwd": "\(cwd)", "command": "", "status": "unknown",
         "createdUnix": 0, "attachedClients": \(attached)}
        """
        return try JSONDecoder().decode(Termiod.SessionInformation.self, from: Data(json.utf8))
    }

    func testANameMatchingACurrentRowChangesNothing() throws {
        let (store, _, project) = makeStore()
        let session = Session(title: "agent", agent: .terminal)
        store.projects[0].sessions = [session]
        _ = project

        let before = store.allSessions.count
        try store.reconcileExternalSessions(
            [information(name: session.id.uuidString)], from: .thisMac, route: .local)

        XCTAssertEqual(store.allSessions.count, before, "an accounted row was adopted twice")
    }

    func testAJournaledNameIsNotAdopted() throws {
        let (store, _, _) = makeStore()
        store.journalClosedSession(named: "orphan", sshAlias: nil)

        let before = store.allSessions.count
        try store.reconcileExternalSessions(
            [information(name: "orphan")], from: .thisMac, route: .local)

        XCTAssertEqual(store.allSessions.count, before,
                       "this app's own orphan was adopted instead of killed")
        XCTAssertTrue(store.closedSessionJournal.contains { $0.name == "orphan" },
                      "the record must survive until the roster stops naming it")
    }

    func testADetachedStrangerAdoptsIntoTheProjectHoldingItsCwd() throws {
        let (store, _, project) = makeStore(projectPath: "/code/termio")

        try store.reconcileExternalSessions(
            [information(name: "cli-started", cwd: "/code/termio/Sources")],
            from: .thisMac, route: .local)

        let adopted = store.projects[0].sessions.first
        XCTAssertNotNil(adopted, "the stranger never landed in the cwd-matching project")
        XCTAssertEqual(adopted?.termiodSessionName, "cli-started",
                       "the row must keep the daemon's name to reach that exact PTY")
        XCTAssertNil(store.selectedSessionID,
                     "auto-adoption moved the selection — nobody clicked anything")
        _ = project
    }

    func testADetachedStrangerOutsideEveryProjectAdoptsAsALooseTerminal() throws {
        let (store, workspace, _) = makeStore()

        try store.reconcileExternalSessions(
            [information(name: "wanderer", cwd: "/somewhere/else")],
            from: .thisMac, route: .local)

        XCTAssertTrue(store.projects[0].sessions.isEmpty)
        let workspaceIndex = store.workspaces.firstIndex { $0.id == workspace.id }
        XCTAssertEqual(
            workspaceIndex.map { store.workspaces[$0].terminals.count }, 1,
            "the stranger belongs in the workspace's loose terminals")
    }

    func testAnAttachedStrangerGetsNoRowOnThisMac() throws {
        let (store, _, _) = makeStore()

        let before = store.allSessions.count
        try store.reconcileExternalSessions(
            [information(name: "theirs", attached: 1)], from: .thisMac, route: .local)

        XCTAssertEqual(store.allSessions.count, before,
                       "a second install's live session is not ours to claim")
    }

    /// The guard is local-only: on a remote device an attached session is still
    /// one of that box's own sessions — read-many is the design — and hiding it
    /// would hide the box's work from the Mac.
    func testAnAttachedStrangerIsAdoptedOnARemoteDevice() throws {
        let (store, _, _) = makeStore()
        let device = KnownDevice(alias: "vps", deviceID: nil)

        let before = store.allSessions.count
        try store.reconcileExternalSessions(
            [information(name: "phones", attached: 1)], from: device, route: .ssh("vps"))

        XCTAssertEqual(store.allSessions.count, before + 1,
                       "the box's own attached session never got a row")
        let adopted = store.allSessions.first { $0.termiodSessionName == "phones" }
        XCTAssertEqual(adopted?.termiodRemoteHost, "vps")
    }

    func testASpentJournalRecordIsDropped() throws {
        let (store, _, _) = makeStore()
        store.journalClosedSession(named: "long-dead", sshAlias: nil)

        try store.reconcileExternalSessions([], from: .thisMac, route: .local)

        XCTAssertFalse(store.closedSessionJournal.contains { $0.name == "long-dead" },
                       "a record whose name the roster no longer lists has done its job")
    }

    /// A record for another route must survive this route's sweep: the close it
    /// remembers can only be settled by the machine it happened on.
    func testAnotherRoutesRecordSurvivesThisSweep() throws {
        let (store, _, _) = makeStore()
        store.journalClosedSession(named: "remote-orphan", sshAlias: "vps")

        try store.reconcileExternalSessions([], from: .thisMac, route: .local)

        XCTAssertTrue(store.closedSessionJournal.contains { $0.name == "remote-orphan" })
    }
}

/// The §D2 demotion through the store: the row transitions in place — status,
/// notice, identity — driven by the same foreground samples the daemon sends.
@MainActor
final class DeclaredAgentDemotionTests: XCTestCase {
    private func makeStore(with session: Session) -> TermioStore {
        let workspace = Workspace(name: "Sessions")
        let project = Project(workspaceID: workspace.id, name: "termio", path: "/code/termio",
                              branch: "main", sessions: [session])
        let defaults = UserDefaults(suiteName: "demotion-\(UUID().uuidString)")
        return TermioStore(workspaces: [workspace], projects: [project],
                           settings: AppSettings(defaults: defaults ?? .standard))
    }

    func testAWrappedAgentExitDemotesTheRowInPlace() {
        let session = Session(title: "agent", agent: .claudeCode)
        let store = makeStore(with: session)
        _ = store.setStatus(.working, for: session.id)

        store.noteDeclaredAgentForeground(["claude"], for: session.id)
        store.noteDeclaredAgentForeground(["-zsh"], for: session.id)
        XCTAssertNil(store.agentExitNotice(for: session.id), "one sample must not demote")
        store.noteDeclaredAgentForeground(["-zsh"], for: session.id)

        XCTAssertEqual(store.status(for: session.id), .idle)
        XCTAssertEqual(store.agentExitNotice(for: session.id), "Claude Code exited — shell")
        XCTAssertEqual(store.session(session.id)?.agent, .claudeCode,
                       "identity is untouched — the row never re-files (#528)")
    }

    func testTheAgentComingBackClearsTheNotice() {
        let session = Session(title: "agent", agent: .claudeCode)
        let store = makeStore(with: session)
        store.noteDeclaredAgentForeground(["-zsh"], for: session.id)
        store.noteDeclaredAgentForeground(["-zsh"], for: session.id)
        XCTAssertNotNil(store.agentExitNotice(for: session.id), "the fixture never demoted")

        store.noteDeclaredAgentForeground(["claude"], for: session.id)

        XCTAssertNil(store.agentExitNotice(for: session.id))
    }

    /// The agent's own subprocess (`rg`, a build) holding the foreground is a
    /// working agent, not an exit — only the login shell counts as evidence.
    func testASubprocessInTheForegroundNeverDemotes() {
        let session = Session(title: "agent", agent: .claudeCode)
        let store = makeStore(with: session)
        _ = store.setStatus(.working, for: session.id)

        for _ in 0..<5 { store.noteDeclaredAgentForeground(["rg", "pattern"], for: session.id) }

        XCTAssertEqual(store.status(for: session.id), .working)
        XCTAssertNil(store.agentExitNotice(for: session.id))
    }
}
