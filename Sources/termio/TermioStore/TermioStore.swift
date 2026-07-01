import AppKit
import Combine
import Foundation
import GhosttyTerminal

/// App-wide state: the project/session tree plus a cache of live terminal
/// surfaces. The cache ("SurfaceCache" in unpeel's terms) keeps one
/// `TerminalViewState` alive per session so switching sessions in the sidebar
/// does not tear down the running shell.
@MainActor
final class TermioStore: ObservableObject {
    @Published var projects: [Project] {
        // Any structural change to the tree (sessions added/closed, projects
        // edited) is written back to disk so the sidebar survives app restarts,
        // and the set of folders whose branch we track live is re-synced.
        didSet {
            persist()
            syncWatchedFolders()
        }
    }
    @Published var selectedSessionID: Session.ID? {
        // Selecting a session means the user is now looking at it, so any pending
        // "needs attention" is, by definition, answered.
        didSet {
            if let id = selectedSessionID {
                statuses[id] = .idle
                currentTool[id] = nil
                lastWorkingAt[id] = nil
                // Switching to a session counts as activity for its project, so the
                // "Recent Activity" sort floats a project the moment you focus it.
                if let pid = project(for: id)?.id { liveActivity[pid] = Date() }
            }
            persist()
        }
    }

    /// When each project was last active — the moment one of its agents last reported
    /// work, or the user last switched to one of its sessions. Drives the sidebar's
    /// "Recent Activity" sort (see `orderedProjects`). In-memory and `@Published` so a
    /// change re-sorts the list live; it deliberately does not persist (a fresh launch
    /// falls back to the stored project order until activity resumes), which keeps the
    /// high-frequency working-event updates off the disk-writing `projects` array.
    @Published var liveActivity: [Project.ID: Date] = [:]

    /// The project whose Security panel is open, or `nil` when none is. Transient UI
    /// state (not persisted) driving the sandbox-configuration sheet.
    @Published var editingSecurityProjectID: Project.ID?

    /// The file currently open in the editor overlay, or `nil` when the terminal is showing.
    /// Transient UI state: clicking a text file in the inspector sets it, and the terminal
    /// pane covers itself with the editor while it is non-nil (see `TerminalPane` / `FileEditorView`).
    /// Opening a file dismisses any open diff — the two overlays are mutually exclusive.
    @Published var openFileURL: URL? {
        didSet {
            if openFileURL != nil { openDiff = nil }
            // Closing always returns to the editable default; a read-only open re-asserts the flag
            // immediately before setting the URL (see `openTerminalLink`).
            else { openFileReadOnly = false }
        }
    }

    /// Whether the open file should be shown read-only (no editing, no auto-save). Set when the file
    /// was opened by cmd-clicking a link in the terminal — a peek at the source, not an invitation to
    /// edit it by mistake. The inspector's own file opens stay editable (`openFileInEditor`).
    @Published var openFileReadOnly = false

    /// The changed file currently shown in the diff overlay, or `nil` when none is. The git
    /// counterpart of `openFileURL`: clicking a row in the Changes pane sets it, and the terminal
    /// pane covers itself with `GitDiffView` while it is non-nil. Opening a diff dismisses any open
    /// file editor.
    @Published var openDiff: GitDiffRequest? {
        didSet { if openDiff != nil { openFileURL = nil } }
    }

    /// Which pane the trailing inspector shows — the file tree or git changes. Set by the toolbar's
    /// segmented switch and read by `FileBrowserView`. (The inspector's open/closed state is owned by
    /// the app delegate's `NSSplitViewItem`, not mirrored here, so the two cannot desync.)
    @Published var inspectorTab: InspectorTab = .files

    /// The repo's dirty-file count, surfaced from the Changes pane so callers can reflect "has
    /// changes" without the inspector being open.
    @Published var gitChangeCount = 0

    /// Per-session activity, driven by terminal signals and, when enabled, agent hooks.
    /// A session with no entry (never opened, so no surface yet) reads as `.idle`.
    @Published var statuses: [Session.ID: SessionStatus] = [:]

    /// The tool a working session is currently running (`PreToolUse.tool_name`),
    /// shown in the session's status tooltip. Cleared when the turn ends.
    @Published var currentTool: [Session.ID: String] = [:]

    /// The running program's live terminal title (`OSC 0/2`) per session, used as
    /// an agent session's display label so two sessions of the same agent stay
    /// distinguishable. The stored `Session.title` is never touched.
    @Published var liveTitles: [Session.ID: String] = [:]

    /// User preferences (appearance, agent commands, worktree behaviour). Held so
    /// surfaces can be configured on creation and re-styled live when settings
    /// change; also handed to the settings UI and sidebar.
    let settings: AppSettings

    /// Live current-branch per folder (project checkouts and session worktrees). The
    /// sidebar's worktree nodes and the terminal title bar read their branch label
    /// from here, so a `git checkout` inside a session updates the UI on its own.
    let branchModel = BranchModel()

    var surfaces: [Session.ID: TerminalViewState] = [:]
    var monitors: [Session.ID: [AnyCancellable]] = [:]
    private var settingsObserver: AnyCancellable?
    private var branchObserver: AnyCancellable?
    private var linkObserver: AnyCancellable?
    private var linkClickMonitor: Any?
    private let stateFile = StateFile()

    /// The socket Claude Code's hooks report into. Runs for the app's lifetime; the
    /// `~/.claude/settings.json` side is what the setting toggles on and off.
    var hookListener: HookListener?
    /// The hooks-enabled value last written to disk, so a settings change only
    /// rewrites the hooks file when this specific setting flips — not on every
    /// unrelated appearance change that also fires `objectWillChange`.
    var installedHooksEnabled: Bool?

    /// The control socket the `termio sessions` CLI drives sibling sessions through.
    /// Runs for the app's lifetime (harmless when the feature is off — the handler
    /// refuses with "disabled"); only the awareness note installed into the agent
    /// instruction files is toggled, mirroring how `hookListener` works.
    var sessionControl: SessionControlListener?
    var installedSessionControlEnabled: Bool?

    /// The agent's own conversation log per session, learned from the hook stream
    /// (Claude Code's `transcript_path`). This is the address `sessions send` hands
    /// back so a caller can read the raw Q&A — and the response — from the agent's
    /// structured log instead of scraping the terminal.
    var transcriptPaths: [Session.ID: String] = [:]

    /// When each currently-working session last reported activity, used to recover
    /// a session whose agent died mid-turn (see `sweepStaleWorking`).
    var lastWorkingAt: [Session.ID: Date] = [:]
    var staleWorkingSweep: Timer?
    /// Long on purpose: tool events refresh `lastWorkingAt` throughout a normal
    /// turn, so this only fires for a genuinely stuck session, and only while the
    /// user is looking elsewhere (selecting clears it anyway).
    let staleWorkingTimeout: TimeInterval = 300

    init(projects: [Project], settings: AppSettings) {
        self.settings = settings
        self.projects = projects
        self.selectedSessionID = projects.first?.sessions.first?.id

        // Re-style already-open terminals whenever appearance settings change.
        // `objectWillChange` fires *before* the new value lands, so we hop to the
        // next main-loop tick to read the updated values (same deferral the
        // menu-bar controller uses).
        settingsObserver = settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.applyAppearanceToOpenSurfaces()
                self?.syncHooksInstallationIfNeeded()
                self?.syncSessionControlInstallationIfNeeded()
            }

        // A branch label changing is not a change to the persisted tree, so the
        // BranchModel owns its own published state; forward its updates into ours so
        // views observing the store (sidebar, terminal title bar) re-render.
        branchObserver = branchModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }

        // Cmd-clicking a link in any terminal surface republishes here (see `TerminalLinkOpening`):
        // route local files into the read-only preview overlay and hand web links to the system.
        linkObserver = NotificationCenter.default.publisher(for: .termioTerminalOpenURL)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self,
                      let url = note.userInfo?[TerminalLinkKey.url] as? String else { return }
                let cwd = (note.object as? TerminalViewState)?.workingDirectory
                self.openTerminalLink(url, surfaceWorkingDirectory: cwd)
            }

        // Open the hovered hyperlink on cmd-click ourselves. ghostty's own `open_url` doesn't reach
        // us in practice — a mouse-capturing TUI (Claude Code) never lets ghostty handle the click,
        // and even a plain shell's click is consumed here first — but the hover delegate always
        // reports the URL under the mouse (`TerminalLinkState.hoveredURL`), so a cmd+left-click opens
        // that link in *both* shells and agent TUIs. Returning nil consumes the event so the click
        // isn't also delivered to the terminal/app underneath.
        linkClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self,
                  event.modifierFlags.contains(.command),
                  let url = TerminalLinkState.hoveredURL else { return event }
            self.openTerminalLink(url, surfaceWorkingDirectory: nil)
            return nil
        }
        syncWatchedFolders()

        startHookMonitoring()
        startSessionControl()
    }

    /// The live branch label for a folder (a project checkout or a session
    /// worktree), or `nil` when it is not a git repo — in which case the UI hides
    /// the branch chip rather than showing an empty token.
    func branch(forFolder folder: String) -> String? {
        branchModel.branch(for: folder)
    }

    /// Tells the BranchModel which folders to keep a live branch for: every project's
    /// own directory plus every session worktree. Called once at init and after any
    /// change to the project tree.
    private func syncWatchedFolders() {
        var folders = Set<String>()
        for project in projects {
            folders.insert(project.path)
            for session in project.sessions {
                if let worktree = session.worktreePath { folders.insert(worktree) }
            }
        }
        branchModel.setWatched(folders)
    }

    /// Builds a store from the persisted session tree, falling back to the seed
    /// projects on first launch (or if the saved state is missing/unreadable).
    /// Live terminal surfaces are not persisted — each session's shell restarts
    /// fresh in its project directory the first time it is opened again.
    static func restored(settings: AppSettings) -> TermioStore {
        guard let snapshot = StateFile().load(), !snapshot.projects.isEmpty else {
            return TermioStore(projects: Project.sampleProjects(), settings: settings)
        }

        let store = TermioStore(projects: normalizingAgentTitles(snapshot.projects), settings: settings)
        if let id = snapshot.selectedSessionID, store.session(id) != nil {
            store.selectedSessionID = id
        }
        return store
    }

    /// Earlier builds saved agent sessions with a lowercased label (`claude code`)
    /// and plain terminals as `session N`. We now keep the agent's real name
    /// (`Claude Code`, `Terminal N`), so upgrade any session whose title is still
    /// one of those old auto-generated forms. A title the user changed to anything
    /// else is left untouched.
    private static func normalizingAgentTitles(_ projects: [Project]) -> [Project] {
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

    private func persist() {
        stateFile.save(.init(
            projects: projects,
            selectedSessionID: selectedSessionID
        ))
    }

    func status(for sessionID: Session.ID) -> SessionStatus {
        statuses[sessionID] ?? .idle
    }

    /// The label to show for a session. Centralized so the sidebar and the
    /// menu-bar tray always agree on what a session is called.
    ///
    /// Agent sessions adopt the running program's live terminal title (`OSC 0/2`)
    /// once it reports something meaningful — that is how a `Claude Code` row
    /// becomes `Explore e2b.dev infra`, keeping two sessions of the same agent
    /// distinguishable. A name the user set themselves (one that differs from the
    /// agent's default display name) wins over the live title.
    ///
    /// Plain terminals never adopt a live title (their shell would just report
    /// `user@host`/cwd noise); instead the auto-named ones (`Terminal N`) all show
    /// a bare `Terminal` label. The stored title is left untouched (it seeds the
    /// worktree branch slug, which must stay stable and unique); only the displayed
    /// value is derived here.
    func displayTitle(for session: Session) -> String {
        if session.agent != .terminal {
            if session.title != session.agent.displayName {
                return session.title
            }
            return liveTitles[session.id] ?? session.title
        }
        guard session.agent == .terminal,
              Self.isAutoTerminalName(session.title) else {
            return session.title
        }
        return "Terminal"
    }

    /// Whether `title` is an auto-generated `Terminal N` label (as opposed to a
    /// name the user chose), which is what makes it eligible for live re-indexing.
    private static func isAutoTerminalName(_ title: String) -> Bool {
        let suffix = title.dropFirst("Terminal ".count)
        return title.hasPrefix("Terminal ") && !suffix.isEmpty
            && suffix.allSatisfy(\.isNumber)
    }

    /// The single state the menu-bar pulse renders: any session waiting on the
    /// user wins, then any working session, then any just-finished one, else calm.
    var aggregateStatus: SessionStatus {
        let all = projects.flatMap(\.sessions).map { status(for: $0.id) }
        if all.contains(.needsAttention) { return .needsAttention }
        if all.contains(.working) { return .working }
        if all.contains(.done) { return .done }
        return .idle
    }

    func session(_ id: Session.ID) -> Session? {
        for project in projects {
            if let session = project.sessions.first(where: { $0.id == id }) {
                return session
            }
        }
        return nil
    }

    func project(for sessionID: Session.ID) -> Project? {
        projects.first { $0.sessions.contains { $0.id == sessionID } }
    }

    /// Opens a file in the editor overlay in its normal **editable** mode — the inspector's own
    /// file-tree click path. Pairs with `openTerminalLink`, which opens read-only; routing through
    /// these two methods (rather than assigning `openFileURL` directly) keeps the read-only flag and
    /// the URL in step.
    func openFileInEditor(_ url: URL) {
        openFileReadOnly = false
        openFileURL = url
    }

    /// Routes a link the user cmd-clicked in a terminal surface. A local file (a `file://` URL, or a
    /// bare path resolved against the surface's working directory) covers the terminal with a
    /// **read-only** preview — the source, not an editable buffer, so a stray click can't change it.
    /// A web/mail link is handed to the system's default handler instead. Anything that resolves to
    /// neither (a dead path, a directory, an unknown scheme) is ignored.
    func openTerminalLink(_ raw: String, surfaceWorkingDirectory: String?) {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }

        if let url = URL(string: link), let scheme = url.scheme?.lowercased() {
            if url.isFileURL {
                presentFilePreview(url)
            } else if ["http", "https", "mailto", "ftp", "ftps"].contains(scheme) {
                NSWorkspace.shared.open(url)
            }
            return
        }

        // No scheme: treat as a filesystem path, absolute or relative to where the surface is `cd`'d.
        let base = surfaceWorkingDirectory ?? selectedSessionWorkspace
        let url: URL = (link as NSString).isAbsolutePath || base == nil
            ? URL(fileURLWithPath: link)
            : URL(fileURLWithPath: link, relativeTo: URL(fileURLWithPath: base!, isDirectory: true))
        presentFilePreview(url.standardizedFileURL)
    }

    /// Covers the terminal with a read-only preview of `url`, but only if it points at an existing
    /// regular file — a missing path or a directory is silently dropped rather than opening an empty
    /// overlay.
    private func presentFilePreview(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return }
        openFileReadOnly = true
        openFileURL = url
    }

    /// The working directory of the selected session (its worktree, else the project root), used as
    /// the fall-back base for resolving a relative path when the surface hasn't reported an OSC 7 cwd.
    private var selectedSessionWorkspace: String? {
        guard let id = selectedSessionID, let session = session(id), let project = project(for: id)
        else { return nil }
        return session.worktreePath ?? project.path
    }
}
