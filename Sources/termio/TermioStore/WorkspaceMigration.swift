import Foundation

/// Turns a pre-workspace state file into workspaces, and carries the older
/// container migrations that used to live in `TermioStore`.
///
/// Everything here is pure and static: it takes the decoded on-disk shape and
/// returns the live one, so a test can pin the upgrade without standing up a
/// store, a window, or a disk. The one rule the whole file exists to keep is
/// that **no session may be lost** — a row the user could see before the upgrade
/// is a row they can see after it.
enum WorkspaceMigration {
    /// A project as state files wrote it before workspaces existed.
    ///
    /// It is decoded separately from `Project` rather than being kept alive as
    /// dead fields on the live model: `kind`, `sshHost`, and the host container's
    /// remote `path` mean nothing once a workspace owns the loose collections, and
    /// a live type carrying them would invite new code to read them.
    struct LegacyProject: Codable {
        /// `.host` is the only kind whose identity is a machine rather than a
        /// local path; the other three are the funnels a workspace replaces.
        enum Kind: String, Codable {
            case folder, terminals, chats, host
        }

        var id: UUID
        var name: String
        var path: String
        var branch: String
        var sessions: [Session]
        var worktrees: [Worktree]
        var pinned: Bool
        var kind: Kind
        var remoteCheckouts: [String: String]
        var sshHost: String?
        var deviceID: String?

        init(
            id: UUID = UUID(), name: String, path: String, branch: String,
            sessions: [Session], worktrees: [Worktree] = [], pinned: Bool = false,
            kind: Kind = .folder, remoteCheckouts: [String: String] = [:],
            sshHost: String? = nil, deviceID: String? = nil
        ) {
            self.id = id
            self.name = name
            self.path = path
            self.branch = branch
            self.sessions = sessions
            self.worktrees = worktrees
            self.pinned = pinned
            self.kind = kind
            self.remoteCheckouts = remoteCheckouts
            self.sshHost = sshHost
            self.deviceID = deviceID
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, path, branch, sessions, worktrees, pinned, kind, remoteCheckouts,
                 sshHost, deviceID
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            path = try c.decode(String.self, forKey: .path)
            branch = try c.decode(String.self, forKey: .branch)
            sessions = try c.decode([Session].self, forKey: .sessions)
            worktrees = try c.decodeIfPresent([Worktree].self, forKey: .worktrees) ?? []
            pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
            kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .folder
            remoteCheckouts =
                try c.decodeIfPresent([String: String].self, forKey: .remoteCheckouts) ?? [:]
            sshHost = try c.decodeIfPresent(String.self, forKey: .sshHost)
            deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
        }
    }

    /// The whole upgrade, in the order the steps have to run: the old per-container
    /// migrations first (each still describes the file it was written for), then
    /// the fold into workspaces.
    ///
    /// The user opens to the sidebar they closed. Everything the sidebar drew for
    /// this Mac — the Terminals funnel, the Chats funnel, every folder project —
    /// becomes workspace #1, so the column looks the way it did. Each `.host`
    /// container becomes that machine's fallback workspace, which is what the
    /// sidebar showed after switching to that device.
    static func migrate(_ legacy: [LegacyProject]) -> (workspaces: [Workspace], projects: [Project]) {
        let upgraded = liftingRemoteSessionsToHosts(
            migratingScratchProject(migratingHomeProject(normalizingAgentTitles(legacy))))

        var home = Workspace(name: Workspace.defaultName)
        var fallbacks: [Workspace] = []
        var projects: [Project] = []

        for container in upgraded {
            switch container.kind {
            case .terminals:
                home.terminals.append(contentsOf: container.sessions)
            case .chats:
                home.chats.append(contentsOf: container.sessions)
            case .host:
                // A machine's container was never a folder: its `path` is a
                // directory on that box and its sessions are loose shells there.
                // As a workspace it keeps both facts and loses the disguise.
                fallbacks.append(Workspace(
                    name: container.sshHost ?? container.name,
                    terminals: container.sessions,
                    deviceAlias: container.sshHost ?? container.name,
                    deviceID: container.deviceID
                ))
            case .folder:
                projects.append(Project(
                    id: container.id,
                    workspaceID: home.id,
                    name: container.name,
                    path: container.path,
                    branch: container.branch,
                    sessions: container.sessions,
                    worktrees: container.worktrees,
                    pinned: container.pinned,
                    remoteCheckouts: container.remoteCheckouts
                ))
            }
        }
        return ([home] + fallbacks, projects)
    }

    /// Files any project whose owner no longer exists — a workspace deleted while
    /// the app was closed, or a project written before workspaces — under the
    /// first workspace, and guarantees there is a first workspace to file it
    /// under. Runs on every load, not just the upgrade: losing the sidebar to a
    /// dangling id is the failure this rules out.
    static func reconcile(
        workspaces: [Workspace], projects: [Project]
    ) -> (workspaces: [Workspace], projects: [Project]) {
        var workspaces = workspaces
        if workspaces.isEmpty { workspaces = [Workspace(name: Workspace.defaultName)] }
        // A user workspace, not a machine's fallback: an orphan is the user's
        // work, and burying it under a box they may never open again hides it.
        let fallbackID = (workspaces.first { !$0.isDeviceFallback } ?? workspaces[0]).id
        let known = Set(workspaces.map(\.id))
        let projects = projects.map { project -> Project in
            guard !known.contains(project.workspaceID) else { return project }
            var project = project
            project.workspaceID = fallbackID
            return project
        }
        return (workspaces, projects)
    }

    // MARK: - The container migrations that came before

    /// Earlier builds saved agent sessions with a lowercased label (`claude code`)
    /// and plain terminals as `session N`. We now keep the agent's real name
    /// (`Claude Code`, `Terminal N`), so upgrade any session whose title is still
    /// one of those old auto-generated forms. A title the user changed to anything
    /// else is left untouched.
    static func normalizingAgentTitles(_ projects: [LegacyProject]) -> [LegacyProject] {
        projects.map { project in
            var project = project
            project.sessions = project.sessions.map { session in
                var session = session
                if session.agent == .terminal {
                    let suffix = session.title.dropFirst("session ".count)
                    if session.title.hasPrefix("session "), !suffix.isEmpty,
                       suffix.allSatisfy(\.isNumber) {
                        session.title = "Terminal \(suffix)"
                    }
                } else if session.title == session.agent.displayName.lowercased() {
                    session.title = session.agent.displayName
                }
                return session
            }
            return project
        }
    }

    /// State files from before the loose-terminals entity existed (see
    /// docs/design/20260713-loose-terminal-entity.md) modeled scratch terminals as a plain
    /// project rooted at `$HOME`. Re-tag that container as `.terminals` so it folds
    /// into the workspace's Terminals section rather than becoming a fake home
    /// project. Idempotent — an already-tagged container passes through unchanged.
    /// The pre-entity seed also called its one shell "shell", which isn't an auto
    /// `Terminal N` name and would block the cwd-basename label, so it is
    /// re-numbered here.
    static func migratingHomeProject(_ projects: [LegacyProject]) -> [LegacyProject] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return projects.map { project in
            var project = project
            // A host container's `path` is a *remote* path, and its default `~`
            // tilde-expands to this Mac's home — without this guard the home rule
            // below would swallow every host into the Terminals funnel on relaunch,
            // undoing exactly what `liftingRemoteSessionsToHosts` just did.
            guard project.kind != .host else { return project }
            guard project.kind == .terminals
                || (project.path as NSString).standardizingPath == home else { return project }
            project.kind = .terminals
            project.name = "Terminals"
            project.sessions = project.sessions.enumerated().map { index, session in
                var session = session
                if session.title == "shell" { session.title = "Terminal \(index + 1)" }
                return session
            }
            return project
        }
    }

    /// State files from before the Chats funnel existed modeled scratch **agent**
    /// sessions as a plain `.folder` project named "default" at `~/.termio/default`.
    /// Re-tag that container as `.chats` so those sessions fold into the
    /// workspace's Chats section rather than a fake "default" project folder.
    /// Matched by its old scratch path; idempotent — an already-tagged `.chats`
    /// container, and any real project, pass through unchanged. Sessions restart
    /// fresh on relaunch anyway, so repointing the spawn path is free.
    static func migratingScratchProject(_ projects: [LegacyProject]) -> [LegacyProject] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let oldPath = home.appendingPathComponent(".termio/default").standardizedFileURL.path
        return projects.map { project in
            guard project.kind == .folder,
                  (project.path as NSString).standardizingPath == oldPath else { return project }
            var project = project
            project.kind = .chats
            project.name = "Chats"
            return project
        }
    }

    /// State files written before the `.host` container existed put every remote
    /// session — plain `ssh` and durable termiod alike — in the `.terminals` funnel,
    /// where a box you SSH into rendered as a loose local shell. Lift each one into
    /// its machine's own container, keyed by alias, preserving session order within
    /// each host. Only the loose funnel is drained: a remote terminal opened *from* a
    /// project belongs to that project (the row you clicked is the row it appears
    /// under), so `.folder` containers are left alone. Idempotent — a state file that
    /// already has its hosts split out has nothing remote left in `.terminals`.
    static func liftingRemoteSessionsToHosts(_ projects: [LegacyProject]) -> [LegacyProject] {
        func alias(_ session: Session) -> String? { session.termiodRemoteHost ?? session.sshHost }
        guard projects.contains(where: { $0.kind == .terminals && $0.sessions.contains { alias($0) != nil } })
        else { return projects }

        var result: [LegacyProject] = []
        // Host containers already in the file absorb the lifted sessions rather than
        // being duplicated, so the merge survives a half-migrated state.
        var hostIndex: [String: Int] = [:]
        for (offset, project) in projects.enumerated() where project.kind == .host {
            if let host = project.sshHost { hostIndex[host] = offset }
        }

        var lifted: [String: [Session]] = [:]
        for var project in projects {
            if project.kind == .terminals {
                for session in project.sessions {
                    guard let host = alias(session) else { continue }
                    lifted[host, default: []].append(session)
                }
                project.sessions = project.sessions.filter { alias($0) == nil }
            }
            result.append(project)
        }

        for (host, sessions) in lifted.sorted(by: { $0.key < $1.key }) {
            // In the funnel a remote session was auto-named for its box, since that
            // was the only thing telling it apart from the local shells around it.
            // Inside the box's own block that name is the header, so it renumbers —
            // `ukvps ▸ ukvps` says the same word twice. Titles the user (or a clone)
            // chose are left exactly as they are.
            var taken = Set(hostIndex[host].map { result[$0].sessions.map(\.title) } ?? [])
            taken.formUnion(sessions.map(\.title))
            var counter = 0
            let renamed = sessions.map { session -> Session in
                guard session.title == host else { return session }
                var session = session
                repeat { counter += 1 } while taken.contains("Terminal \(counter)")
                session.title = "Terminal \(counter)"
                taken.insert(session.title)
                return session
            }
            if let existing = hostIndex[host] {
                result[existing].sessions.append(contentsOf: renamed)
            } else {
                // The remote cwd is the session's own property, so the container's
                // root stays `~` unless a session already records one.
                let root = renamed.compactMap(\.termiodRemoteCwd).first
                result.append(LegacyProject(
                    name: host, path: root ?? "~", branch: "—",
                    sessions: renamed, kind: .host, sshHost: host
                ))
            }
        }
        // A funnel emptied by the lift is dropped: an empty Terminals section is
        // hidden in the sidebar anyway, and keeping it would resurrect on next launch.
        return result.filter { $0.kind != .terminals || !$0.sessions.isEmpty }
    }
}
