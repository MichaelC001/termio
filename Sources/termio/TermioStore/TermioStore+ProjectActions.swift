import AppKit
import Foundation

extension TermioStore {
    /// Adds a session to a project, running in the project's directory.
    func addSession(to projectID: Project.ID, agent: AgentPreset = .terminal) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let project = projects[index]
        let terminalCount = project.sessions.filter { $0.agent == .terminal }.count
        let title = agent == .terminal
            ? "Terminal \(terminalCount + 1)"
            : agent.displayName
        let session = Session(title: title, agent: agent)
        projects[index].sessions.append(session)
        selectedSessionID = session.id
    }

    /// Opens a fresh scratch terminal — a plain login shell in the user's home
    /// directory, the way launching a new iTerm2 window drops you at `~`. Loose
    /// terminals aren't tied to a real project, so they're gathered under a single
    /// home-rooted section that's created on first use; each later click just adds
    /// another `Terminal N` row there and selects it (the same grow-in-place a
    /// project's own header buttons do). The section persists like any project, so
    /// it reappears on relaunch (the shells themselves restart fresh).
    func addScratchTerminal() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if let existing = projects.first(where: { $0.path == home }) {
            addSession(to: existing.id, agent: .terminal)
            return
        }
        let session = Session(title: "Terminal 1")
        let project = Project(
            name: (home as NSString).lastPathComponent,
            path: home,
            branch: currentBranch(in: home) ?? "—",
            sessions: [session]
        )
        projects.append(project)
        selectedSessionID = session.id
    }

    /// The projects in sidebar display order: pinned ones first, then the rest, each
    /// group ordered by the user's chosen sort (`AppSettings.projectSortOrder`). A
    /// computed view over `projects` — the stored array keeps its own insertion order,
    /// so ordering is a presentation concern that never mutates (or persists) the tree.
    var orderedProjects: [Project] {
        let order = settings.projectSortOrder
        return projects.sorted { a, b in
            // Pinned projects always float to the top, whichever sort is active.
            if a.pinned != b.pinned { return a.pinned }
            switch order {
            case .name:
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .recentActivity:
                let da = liveActivity[a.id] ?? .distantPast
                let db = liveActivity[b.id] ?? .distantPast
                // Newer activity first; equal timestamps keep the array's stable order
                // (Swift's sort is stable), so untouched projects hold their positions.
                if da != db { return da > db }
                return false
            }
        }
    }

    /// Pins or unpins a project. Pinned projects sort ahead of the rest in the sidebar
    /// (see `orderedProjects`); the flag persists via `projects`' `didSet`.
    func togglePinned(_ id: Project.ID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].pinned.toggle()
    }

    /// Presents a folder picker. `sandboxed` decides whether the opened project runs
    /// its sessions under a Seatbelt sandbox (File ▸ Open Project Sandboxed…) or on the
    /// host (File ▸ Open Project…) — the sandbox is decided when the project is brought
    /// in, and can be adjusted later from the project's Security panel.
    func presentOpenProjectPanel(sandboxed: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = sandboxed ? "Open Sandboxed" : "Open"
        panel.message = sandboxed
            ? "Choose a project folder to open under a Seatbelt sandbox."
            : "Choose a project folder to open in termio."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addProject(at: url, sandboxed: sandboxed)
    }

    /// Adds the directory at `url` as a new project section seeded with a single
    /// terminal session, which becomes the selection. A folder already open as a
    /// project is not duplicated — its first session is selected instead. `sandboxed`
    /// seeds the project's sandbox profile so its sessions run under a Seatbelt profile.
    func addProject(at url: URL, sandboxed: Bool = false) {
        let path = url.standardizedFileURL.path
        if let existing = projects.first(where: { $0.path == path }) {
            selectedSessionID = existing.sessions.first?.id
            return
        }
        let session = Session(title: "Terminal 1")
        let project = Project(
            name: url.lastPathComponent,
            path: path,
            branch: currentBranch(in: path) ?? "—",
            sessions: [session],
            sandbox: sandboxed ? SandboxProfile() : nil
        )
        projects.append(project)
        selectedSessionID = project.sessions.first?.id
    }

    /// Turns the per-project sandbox on or off. On flips `sandbox` to a default
    /// `SandboxProfile`; off clears it. Only sessions opened *after* the change pick
    /// it up — an already-running session keeps its cached surface — so the user opens
    /// a fresh session to enter (or leave) the sandbox. The change persists via the
    /// `projects` `didSet`.
    func setSandbox(_ enabled: Bool, for id: Project.ID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].sandbox = enabled ? SandboxProfile() : nil
    }

    /// The sandbox profile of a project, or `nil` when the project runs on the host.
    func sandboxProfile(for id: Project.ID) -> SandboxProfile? {
        projects.first(where: { $0.id == id })?.sandbox
    }

    /// Edits a sandboxed project's profile in place (a no-op when the project isn't
    /// sandboxed). The mutation persists via the `projects` `didSet`, and is picked up by
    /// sessions opened after the change — the Security panel edits through here.
    func updateSandbox(for id: Project.ID, _ mutate: (inout SandboxProfile) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }),
              var profile = projects[index].sandbox else { return }
        mutate(&profile)
        projects[index].sandbox = profile
    }

    /// Removes a project from the sidebar: tears down every session's live surface
    /// (and its PTY) and drops the project from the tree. Only the sidebar entry is
    /// removed — the folder on disk, and any git worktrees the sessions created, are
    /// deliberately left untouched, the same hands-off stance `closeSession` takes
    /// (they may hold uncommitted agent work, so deletion is the user's call).
    func removeProject(_ id: Project.ID) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == id }) else { return }

        let removedSessionIDs = Set(projects[projectIndex].sessions.map(\.id))
        for sessionID in removedSessionIDs {
            SandboxLauncher.cleanUp(sessionID: sessionID)
            ptyProcesses[sessionID]?.terminate()
            ptyProcesses[sessionID] = nil
            surfaces[sessionID] = nil
            monitors[sessionID] = nil
            statuses[sessionID] = nil
            currentTool[sessionID] = nil
            liveTitles[sessionID] = nil
            lastWorkingAt[sessionID] = nil
        }
        projects.remove(at: projectIndex)

        // If the active session lived in the removed project, fall back to the first
        // session of whatever project remains (nil when the sidebar is now empty).
        if let selected = selectedSessionID, removedSessionIDs.contains(selected) {
            selectedSessionID = projects.first(where: { !$0.sessions.isEmpty })?.sessions.first?.id
        }
    }

    /// Closes a session: drops its cached surface (which tears down the PTY) and
    /// moves the selection to a neighbouring session if the closed one was active.
    /// Any git worktree created for the session is deliberately left on disk — it
    /// may hold uncommitted agent work, so cleanup is the user's call, not ours.
    func closeSession(_ id: Session.ID) {
        guard let projectIndex = projects.firstIndex(where: { $0.sessions.contains { $0.id == id } }),
              let sessionIndex = projects[projectIndex].sessions.firstIndex(where: { $0.id == id })
        else { return }

        projects[projectIndex].sessions.remove(at: sessionIndex)
        SandboxLauncher.cleanUp(sessionID: id)
        ptyProcesses[id]?.terminate()
        ptyProcesses[id] = nil
        surfaces[id] = nil
        monitors[id] = nil
        statuses[id] = nil
        currentTool[id] = nil
        liveTitles[id] = nil
        lastWorkingAt[id] = nil

        if selectedSessionID == id {
            let remaining = projects[projectIndex].sessions
            if remaining.isEmpty {
                selectedSessionID = projects.first(where: { !$0.sessions.isEmpty })?.sessions.first?.id
            } else {
                selectedSessionID = remaining[min(sessionIndex, remaining.count - 1)].id
            }
        }
    }

    /// The checked-out branch of the git repository at `directory`, or `nil` when
    /// it is not a repo (rendered as "—", matching the seed projects).
    private func currentBranch(in directory: String) -> String? {
        runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
    }

    /// Runs `git -C <directory> <arguments…>` synchronously, returning trimmed
    /// stdout on success or `nil` on a launch failure or non-zero exit. Callers
    /// treat `nil` as "couldn't do it" and fall back rather than trapping.
    @discardableResult
    private func runGit(_ arguments: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("termio: git could not be launched: \(error)\n".utf8))
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
