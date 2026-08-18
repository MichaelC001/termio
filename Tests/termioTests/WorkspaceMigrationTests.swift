import XCTest
@testable import termio

/// `WorkspaceMigration` — the upgrade that turns a pre-workspace state file into
/// workspaces. It rewrites persisted user state on launch, so the cases that
/// matter are the destructive ones: don't lose a session, open to the sidebar the
/// user closed, and don't leave a project pointing at an owner that isn't there.
final class WorkspaceMigrationTests: XCTestCase {
    private typealias Legacy = WorkspaceMigration.LegacyProject

    private func session(_ title: String, agent: AgentPreset = .terminal) -> Session {
        Session(title: title, agent: agent)
    }

    private func remote(_ title: String, host: String) -> Session {
        var session = Session(title: title, agent: .terminal)
        session.termiodRemoteHost = host
        return session
    }

    private func terminals(_ sessions: [Session]) -> Legacy {
        Legacy(name: "Terminals", path: NSHomeDirectory(), branch: "—",
               sessions: sessions, kind: .terminals)
    }

    private func chats(_ sessions: [Session]) -> Legacy {
        Legacy(name: "Chats",
               path: NSHomeDirectory() + "/.termio/chats", branch: "—",
               sessions: sessions, kind: .chats)
    }

    private func folder(_ name: String, sessions: [Session] = []) -> Legacy {
        Legacy(name: name, path: "/code/\(name)", branch: "main", sessions: sessions)
    }

    /// The whole point of the upgrade: the user opens to the column they closed.
    /// Terminals, Chats and every folder project land in one workspace, so the
    /// switcher stays out of sight for someone who never asked for a second scope.
    func testEverythingThisMacShowedBecomesOneWorkspace() {
        let (workspaces, projects) = WorkspaceMigration.migrate([
            terminals([session("Terminal 1")]),
            chats([session("Claude Code", agent: .claudeCode)]),
            folder("termio", sessions: [session("Terminal 1")]),
            folder("vibewizard"),
        ])

        XCTAssertEqual(workspaces.count, 1, "one workspace, so the switcher stays hidden")
        XCTAssertEqual(workspaces.first?.terminals.map { $0.title }, ["Terminal 1"])
        XCTAssertEqual(workspaces.first?.chats.map { $0.title }, ["Claude Code"])
        XCTAssertEqual(projects.map { $0.name }, ["termio", "vibewizard"])
        XCTAssertEqual(Set(projects.map { $0.workspaceID }), [workspaces[0].id])
    }

    /// A machine's container was never a folder — its path is a directory on that
    /// box and its rows are loose shells there. It becomes that machine's own
    /// workspace, which is exactly what the sidebar showed after switching device.
    func testAHostContainerBecomesThatMachinesWorkspace() {
        let (workspaces, projects) = WorkspaceMigration.migrate([
            terminals([session("Terminal 1")]),
            Legacy(name: "ukvps", path: "/home/me/repo", branch: "—",
                   sessions: [remote("Terminal 1", host: "ukvps")],
                   kind: .host, sshHost: "ukvps", deviceID: "h_aaaa"),
        ])

        XCTAssertTrue(projects.isEmpty, "a machine is not a folder")
        XCTAssertEqual(workspaces.count, 2)
        let fallback = workspaces.first { $0.isDeviceFallback }
        XCTAssertEqual(fallback?.name, "ukvps")
        XCTAssertEqual(fallback?.deviceAlias, "ukvps")
        XCTAssertEqual(fallback?.deviceID, "h_aaaa", "the machine it resolved to is kept")
        XCTAssertEqual(fallback?.terminals.map { $0.title }, ["Terminal 1"])
    }

    /// The hard rule: nothing the user could see before the upgrade is missing
    /// after it, whatever the mix of containers.
    func testNoSessionIsLost() {
        let input: [Legacy] = [
            terminals([session("l1"), session("l2")]),
            chats([session("Claude Code", agent: .claudeCode)]),
            folder("termio", sessions: [session("p1"), session("p2")]),
            Legacy(name: "ukvps", path: "~", branch: "—",
                   sessions: [remote("r1", host: "ukvps")], kind: .host, sshHost: "ukvps"),
        ]

        let (workspaces, projects) = WorkspaceMigration.migrate(input)

        let before = Set(input.flatMap { $0.sessions.map { $0.id } })
        let after = Set(workspaces.flatMap { $0.looseSessions.map { $0.id } }
            + projects.flatMap { $0.sessions.map { $0.id } })
        XCTAssertEqual(after, before)
    }

    /// A project keeps its identity across the upgrade — its id is what the split
    /// groups, the recent list, and the CLI's scope all address it by.
    func testProjectsKeepTheirIdentityAndContents() {
        let original = folder("termio", sessions: [session("Terminal 1")])
        let (_, projects) = WorkspaceMigration.migrate([original])

        XCTAssertEqual(projects.first?.id, original.id)
        XCTAssertEqual(projects.first?.path, "/code/termio")
        XCTAssertEqual(projects.first?.branch, "main")
        XCTAssertEqual(projects.first?.sessions.map { $0.id }, original.sessions.map { $0.id })
    }

    /// The older container migrations still run ahead of the fold, so a state file
    /// two upgrades behind lands in the right sections rather than as fake folders.
    func testOlderContainerMigrationsStillRunFirst() {
        // Pre-loose-terminal-entity: scratch shells were a plain project at $HOME.
        // Pre-chats-funnel: scratch agents were a "default" project at ~/.termio/default.
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let (workspaces, projects) = WorkspaceMigration.migrate([
            Legacy(name: "home", path: home.path, branch: "—", sessions: [session("shell")]),
            Legacy(name: "default",
                   path: home.appendingPathComponent(".termio/default").path,
                   branch: "—", sessions: [session("Claude Code", agent: .claudeCode)]),
        ])

        XCTAssertTrue(projects.isEmpty, "neither was ever a real project")
        XCTAssertEqual(workspaces.first?.terminals.map { $0.title }, ["Terminal 1"],
                       "the pre-entity “shell” is renumbered")
        XCTAssertEqual(workspaces.first?.chats.map { $0.title }, ["Claude Code"])
    }

    /// A remote session left in the loose funnel by a two-versions-old file is
    /// lifted onto its machine before the fold, so it ends up in that machine's
    /// workspace rather than among the local shells.
    func testRemoteSessionsInTheLooseFunnelReachTheirMachinesWorkspace() {
        let (workspaces, _) = WorkspaceMigration.migrate([
            terminals([session("Terminal 1"), remote("Terminal 2", host: "ukvps")]),
        ])

        XCTAssertEqual(workspaces.count, 2)
        XCTAssertEqual(workspaces.first?.terminals.map { $0.title }, ["Terminal 1"])
        XCTAssertEqual(workspaces.last?.deviceAlias, "ukvps")
        XCTAssertEqual(workspaces.last?.terminals.count, 1)
    }

    /// An empty state file still produces a scope: the sidebar has to have one to
    /// show, and a project can never be left pointing at nothing.
    func testMigratingNothingStillProducesAWorkspace() {
        let (workspaces, projects) = WorkspaceMigration.migrate([])

        XCTAssertEqual(workspaces.count, 1)
        XCTAssertTrue(projects.isEmpty)
    }

    /// The published `state.json` shape, decoded through the snapshot the app
    /// actually loads and then migrated. This is the end-to-end check the released
    /// app depends on: the file on a user's disk carries `kind`/`sshHost` on each
    /// project and no `workspaces` key at all, and it has to come back as a
    /// sidebar rather than as a fresh install.
    func testAPublishedStateFileDecodesAndMigrates() throws {
        let json = Data("""
        {
          "projects": [
            {"id": "\(UUID().uuidString)", "name": "Terminals", "path": "\(NSHomeDirectory())",
             "branch": "—", "kind": "terminals",
             "sessions": [{"id": "\(UUID().uuidString)", "title": "Terminal 1",
                           "agent": "terminal", "createdAt": 750000000}]},
            {"id": "\(UUID().uuidString)", "name": "termio", "path": "/code/termio",
             "branch": "main",
             "sessions": [{"id": "\(UUID().uuidString)", "title": "Claude Code",
                           "agent": "claude-code", "createdAt": 750000000}]},
            {"id": "\(UUID().uuidString)", "name": "ukvps", "path": "~", "branch": "—",
             "kind": "host", "sshHost": "ukvps",
             "sessions": [{"id": "\(UUID().uuidString)", "title": "Terminal 1",
                           "agent": "terminal", "createdAt": 750000000,
                           "termiodRemoteHost": "ukvps"}]}
          ]
        }
        """.utf8)

        let snapshot = try JSONDecoder().decode(StateFile.Snapshot.self, from: json)
        XCTAssertNil(snapshot.workspaces, "a published file has no workspaces key")
        let legacy = try XCTUnwrap(snapshot.legacyProjects, "it decodes through the old shape")
        XCTAssertEqual(legacy.count, 3)

        let (workspaces, projects) = WorkspaceMigration.migrate(legacy)

        XCTAssertEqual(workspaces.count, 2, "this Mac's sidebar, plus the machine's own")
        XCTAssertEqual(workspaces.first?.terminals.count, 1)
        XCTAssertEqual(projects.map { $0.name }, ["termio"])
        XCTAssertEqual(projects.first?.workspaceID, workspaces.first?.id)
        XCTAssertEqual(workspaces.last?.deviceAlias, "ukvps")
        XCTAssertEqual(workspaces.last?.terminals.count, 1)
    }

    /// A state file this build wrote skips the upgrade entirely — the legacy read
    /// is what tells the two apart, and it must not fire on a current file.
    func testAWorkspaceEraFileIsNotMigratedAgain() throws {
        let home = Workspace(name: "Sessions", terminals: [session("Terminal 1")])
        let written = StateFile.Snapshot(
            workspaces: [home], currentWorkspaceID: home.id,
            projects: [Project(workspaceID: home.id, name: "termio", path: "/code/termio",
                               branch: "main", sessions: [])],
            selectedSessionID: nil, splitGroups: [], inspectorLayouts: nil)

        let decoded = try JSONDecoder().decode(
            StateFile.Snapshot.self, from: try JSONEncoder().encode(written))

        XCTAssertNil(decoded.legacyProjects, "nothing to upgrade")
        XCTAssertEqual(decoded.workspaces?.first?.terminals.map { $0.title }, ["Terminal 1"])
        XCTAssertEqual(decoded.currentWorkspaceID, home.id)
        XCTAssertEqual(decoded.projects.first?.workspaceID, home.id)
    }

    /// A project whose owner is gone — a workspace deleted while the app was
    /// closed — is filed under the first one rather than vanishing from the tree.
    func testReconcileRehomesAProjectWhoseWorkspaceIsGone() {
        let home = Workspace(name: "Sessions")
        let orphan = Project(workspaceID: UUID(), name: "termio", path: "/code/termio",
                             branch: "main", sessions: [session("Terminal 1")])

        let (workspaces, projects) = WorkspaceMigration.reconcile(
            workspaces: [home], projects: [orphan])

        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(projects.first?.workspaceID, home.id)
    }

    /// An orphan is the user's own work, so it is never buried in a machine's
    /// fallback — those hold what nobody filed, which is the opposite claim.
    func testReconcilePrefersAUserWorkspaceOverAMachineFallback() {
        let fallback = Workspace(name: "ukvps", deviceAlias: "ukvps")
        let home = Workspace(name: "Sessions")
        let orphan = Project(workspaceID: UUID(), name: "termio", path: "/code/termio",
                             branch: "main", sessions: [])

        let (_, projects) = WorkspaceMigration.reconcile(
            workspaces: [fallback, home], projects: [orphan])

        XCTAssertEqual(projects.first?.workspaceID, home.id)
    }

    /// Reconcile leaves a well-formed tree exactly as it found it — it runs on
    /// every load, so it has to be a no-op in the normal case.
    func testReconcileLeavesAHealthyTreeAlone() {
        let home = Workspace(name: "Sessions")
        let filed = Project(workspaceID: home.id, name: "termio", path: "/code/termio",
                            branch: "main", sessions: [])

        let (workspaces, projects) = WorkspaceMigration.reconcile(
            workspaces: [home], projects: [filed])

        XCTAssertEqual(workspaces, [home])
        XCTAssertEqual(projects, [filed])
    }

    /// The upgrade runs once. A state file that already carries workspaces is
    /// never handed to `migrate`, and re-running it over its own output would be a
    /// sign the snapshot decode had gone wrong — so pin that the fold is stable.
    func testMigratingIsStableOverItsOwnShape() {
        let once = WorkspaceMigration.migrate([
            terminals([session("Terminal 1")]),
            folder("termio", sessions: [session("Terminal 1")]),
        ])
        let reconciled = WorkspaceMigration.reconcile(
            workspaces: once.workspaces, projects: once.projects)

        XCTAssertEqual(reconciled.workspaces, once.workspaces)
        XCTAssertEqual(reconciled.projects, once.projects)
    }
}
