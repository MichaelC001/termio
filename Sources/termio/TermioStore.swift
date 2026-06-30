import AppKit
import Combine
import Foundation
import GhosttyTerminal
import GhosttyTheme

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
            }
            persist()
        }
    }

    /// The project whose Security panel is open, or `nil` when none is. Transient UI
    /// state (not persisted) driving the sandbox-configuration sheet.
    @Published var editingSecurityProjectID: Project.ID?

    /// The file currently open in the editor overlay, or `nil` when the terminal is showing.
    /// Transient UI state: double-clicking a text file in the inspector sets it, and the terminal
    /// pane covers itself with the editor while it is non-nil (see `TerminalPane` / `FileEditorView`).
    /// Opening a file dismisses any open diff — the two overlays are mutually exclusive.
    @Published var openFileURL: URL? {
        didSet { if openFileURL != nil { openDiff = nil } }
    }

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

    /// Per-session activity, driven by the surface signals monitored below and, when
    /// enabled, the Claude Code hooks reported into `HookListener`. A session with no
    /// entry (never opened, so no surface yet) reads as `.idle`.
    @Published private(set) var statuses: [Session.ID: SessionStatus] = [:]

    /// The tool a working session is currently running (`PreToolUse.tool_name`),
    /// shown in the session's status tooltip. Cleared when the turn ends. Only
    /// populated while the Claude Code hooks layer is active.
    @Published private(set) var currentTool: [Session.ID: String] = [:]

    /// The running program's live terminal title (`OSC 0/2`) per session, used as
    /// an agent session's display label so two sessions of the same agent stay
    /// distinguishable (e.g. one `Claude Code` reads `Explore e2b.dev infra` and
    /// another `Fix CBT`). Only meaningful values land here (see
    /// `isMeaningfulLiveTitle`); the stored `Session.title` is never touched, so
    /// the worktree branch slug stays stable. No entry falls back to the label.
    @Published private(set) var liveTitles: [Session.ID: String] = [:]

    /// User preferences (appearance, agent commands, worktree behaviour). Held so
    /// surfaces can be configured on creation and re-styled live when settings
    /// change; also handed to the settings UI and sidebar.
    let settings: AppSettings

    /// Live current-branch per folder (project checkouts and session worktrees). The
    /// sidebar's worktree nodes and the terminal title bar read their branch label
    /// from here, so a `git checkout` inside a session updates the UI on its own.
    let branchModel = BranchModel()


    private var surfaces: [Session.ID: TerminalViewState] = [:]
    private var monitors: [Session.ID: [AnyCancellable]] = [:]
    private var settingsObserver: AnyCancellable?
    private var branchObserver: AnyCancellable?
    private let stateFile = StateFile()

    /// The socket Claude Code's hooks report into. Runs for the app's lifetime; the
    /// `~/.claude/settings.json` side is what the setting toggles on and off.
    private var hookListener: HookListener?
    /// The hooks-enabled value last written to disk, so a settings change only
    /// rewrites the hooks file when this specific setting flips — not on every
    /// unrelated appearance change that also fires `objectWillChange`.
    private var installedHooksEnabled: Bool?

    /// The control socket the `termio sessions` CLI drives sibling sessions through.
    /// Runs for the app's lifetime (harmless when the feature is off — the handler
    /// refuses with "disabled"); only the awareness note installed into the agent
    /// instruction files is toggled, mirroring how `hookListener` works.
    private var sessionControl: SessionControlListener?
    private var installedSessionControlEnabled: Bool?

    /// When each currently-working session last reported activity, used to recover
    /// a session whose agent died mid-turn (see `sweepStaleWorking`).
    private var lastWorkingAt: [Session.ID: Date] = [:]
    private var staleWorkingSweep: Timer?
    /// Long on purpose: tool events refresh `lastWorkingAt` throughout a normal
    /// turn, so this only fires for a genuinely stuck session, and only while the
    /// user is looking elsewhere (selecting clears it anyway).
    private let staleWorkingTimeout: TimeInterval = 300

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

    /// Returns the cached terminal surface for a session, creating and starting
    /// it on first access. The surface launches `session.command` (or the login
    /// shell) in the project's working directory via the real PTY (`.exec`).
    func surface(for session: Session, in project: Project) -> TerminalViewState {
        if let existing = surfaces[session.id] {
            return existing
        }

        let agentCommand = settings.command(for: session.agent)
        // An isolated worktree (if one was created for this session) wins over the
        // project's own directory, so the agent edits the branch in place — and so the
        // sandbox's writable workspace is exactly where the session actually works.
        let workspacePath = session.worktreePath ?? project.path

        // When the project is sandboxed, the session's whole process tree runs under a
        // Seatbelt profile compiled from `project.sandbox`: `sandbox-exec` wraps the same
        // command that would otherwise run on the host, the agent is told to stand down
        // its own (now redundant, and un-nestable) sandbox, and everything outside the
        // workspace and the baseline allows is invisible. `nil` (no sandbox, or the
        // profile file couldn't be written) falls back to running on the host as before.
        let sandboxedCommand: String? = project.sandbox.flatMap { profile in
            SandboxLauncher.command(agentCommand: agentCommand, agent: session.agent,
                                    profile: profile, workspacePath: workspacePath,
                                    sessionID: session.id)
        }

        let controller = TerminalController { [self] builder in
            if let sandboxedCommand {
                builder.withCustom("command", sandboxedCommand)
            } else if let agentCommand {
                builder.withCustom("command", agentCommand)
            }
            // Stamp the session's id into the shell environment so any agent hook
            // (Claude/Codex/Pi/OpenCode) running inside it can echo it back, letting
            // `HookListener` correlate events to this exact session even when several
            // share one project directory. Ghostty's `env` key adds it to the PTY.
            builder.withCustom("env", "TERMIO_SESSION=\(session.id.uuidString)")
            applyAppearance(to: &builder)
        }
        let state = TerminalViewState(controller: controller)
        state.controller.setTheme(makeTheme())
        state.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: workspacePath
        )
        surfaces[session.id] = state
        monitor(state, for: session.id)
        warmUpRendering(state)
        return state
    }

    /// Drives the terminal through its startup render handshake.
    ///
    /// Unlike Ghostty.app — which ticks `ghostty_app_tick` every vsync via a
    /// display link — this libghostty embedding has no continuous tick on macOS:
    /// it advances the core only reactively, one hop per PTY-output wakeup, and
    /// those wakeups are edge-triggered (a missed edge is not re-queued). Most
    /// agents paint their grid unconditionally, so a later layout/focus tick
    /// flushes them. OpenCode's renderer instead performs a multi-round-trip,
    /// reply-gated terminal-capability handshake (cursor-position, device
    /// attributes, colour and mode queries) and paints nothing until it is
    /// answered; a single dropped wakeup in that window leaves it blank forever.
    ///
    /// Pumping the core at display rate across the spawn-and-handshake window
    /// lets the round-trips complete. Once the surface has produced content its
    /// own render callbacks sustain later frames, so the pump stops a short grace
    /// after the surface reports a size, with a hard backstop in case it never
    /// attaches (the session was created but never shown).
    private func warmUpRendering(_ state: TerminalViewState) {
        let started = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak state] timer in
            guard let state else { timer.invalidate(); return }
            state.controller.tick()
            let elapsed = Date().timeIntervalSince(started)
            if (state.surfaceSize != nil && elapsed > 2.0) || elapsed > 6.0 {
                timer.invalidate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Builds the live appearance config shared by surface creation and the
    /// re-style path.
    private func appearanceConfiguration() -> TerminalConfiguration {
        TerminalConfiguration { builder in
            applyAppearance(to: &builder)
        }
    }

    /// Translates `AppSettings` (plain values) into Ghostty config commands. This
    /// is the single place terminal-core keys are named, so surface creation and
    /// the live re-style path can never drift apart. Everything here is accepted
    /// by `setTerminalConfiguration`, which reconfigures a running surface in
    /// place — no shell restart.
    private func applyAppearance(to builder: inout TerminalConfiguration.Builder) {
        if !settings.fontFamily.isEmpty {
            builder.withFontFamily(settings.fontFamily)
        }
        builder.withFontSize(Float(settings.fontSize))
        builder.withFontThicken(settings.fontThicken)

        // `CursorStyle`'s raw values are the Ghostty cursor tokens, so this bridge
        // is a straight rawValue hand-off (the guard is just belt-and-braces).
        if let style = TerminalCursorStyle(rawValue: settings.cursorStyle.rawValue) {
            builder.withCursorStyle(style)
        }
        builder.withCursorStyleBlink(settings.cursorBlink)

        // Horizontal padding is the terminal's left/right margin (the tunable
        // Padding setting). Vertical is kept tight on purpose: the title bar sits
        // directly above the surface, so matching the setting there would open a
        // visible gap between the title and the first prompt line.
        builder.withWindowPaddingX(settings.windowPadding)
        builder.withWindowPaddingY(2)
        builder.withBackgroundOpacity(settings.backgroundOpacity)
        builder.withBackgroundBlur(settings.backgroundBlur)

        // Ghostty measures scrollback in bytes; the UI speaks megabytes.
        builder.withCustom("scrollback-limit", String(settings.scrollbackMegabytes * 1_000_000))
        // `clipboard` routes a selection to the system pasteboard; `false` leaves
        // selection copy-free (Ghostty's own default uses the X11 selection, which
        // is meaningless on macOS).
        builder.withCustom("copy-on-select", settings.copyOnSelect ? "clipboard" : "false")
    }

    /// The light/dark theme pair libghostty switches between as the system
    /// appearance changes. Each slot resolves its own chosen Ghostty theme, falling
    /// back to termio's default when none is chosen (or the name no longer
    /// resolves). The light default is a pure-white canvas rather than libghostty's
    /// Alabaster (#F7F7F7): the agent UIs paint their own grey panels over it, so an
    /// off-white background just reads as unstyled. The dark default is Afterglow.
    private func makeTheme() -> TerminalTheme {
        TerminalTheme(
            light: themeConfiguration(named: settings.lightThemeName) ?? .alabaster.background("FFFFFF"),
            dark: themeConfiguration(named: settings.darkThemeName) ?? .afterglow
        )
    }

    /// Resolves a chosen theme name to its terminal configuration, or `nil` when the
    /// slot is left on the default or the name no longer resolves.
    private func themeConfiguration(named name: String) -> TerminalConfiguration? {
        guard !name.isEmpty, let definition = ThemeLibrary.theme(named: name) else { return nil }
        return definition.toTerminalConfiguration()
    }

    /// Pushes the current font and theme onto every live surface without tearing
    /// down its shell — libghostty reconfigures the running terminal in place.
    ///
    /// Reconfiguring updates the core's config but does not itself repaint: this
    /// embedding has no continuous tick (see `warmUpRendering`), so a surface only
    /// redraws on its next PTY-output wakeup. Without a nudge a theme or font change
    /// would not show until the user typed or the agent printed. So when a setter
    /// reports an actual change, pump the core briefly to flush the redraw now.
    private func applyAppearanceToOpenSurfaces() {
        let appearance = appearanceConfiguration()
        let theme = makeTheme()
        for state in surfaces.values {
            let configChanged = state.controller.setTerminalConfiguration(appearance)
            let themeChanged = state.controller.setTheme(theme)
            if configChanged || themeChanged {
                pumpRendering(state, duration: 0.5)
            }
        }
    }

    /// Drives `ghostty_app_tick` at display rate for a short window so a config
    /// change (theme, font, padding) repaints the live surface immediately, rather
    /// than waiting for the next PTY-output wakeup. A fixed short pump is enough: a
    /// color/font reconfigure needs no reply-gated handshake the way a cold spawn
    /// does, so a handful of frames flush the new look.
    private func pumpRendering(_ state: TerminalViewState, duration: TimeInterval) {
        let started = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak state] timer in
            guard let state else { timer.invalidate(); return }
            state.controller.tick()
            if Date().timeIntervalSince(started) > duration {
                timer.invalidate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Watches the surface's already-published activity signals and flags the
    /// session as needing attention when it rings the bell or posts a desktop
    /// notification while the user is looking elsewhere. (Claude Code emits
    /// OSC 9/99 notifications natively inside Ghostty, so this works with no
    /// per-agent configuration.) Selecting the session clears the flag.
    private func monitor(_ state: TerminalViewState, for id: Session.ID) {
        let flag: () -> Void = { [weak self] in
            guard let self, self.selectedSessionID != id else { return }
            self.statuses[id] = .needsAttention
        }
        monitors[id] = [
            state.$lastBellAt.dropFirst().compactMap { $0 }.sink { _ in flag() },
            state.$lastDesktopNotificationAt.dropFirst().compactMap { $0 }.sink { _ in flag() },
            // The surface already publishes the program's live `OSC 0/2` title;
            // adopt the meaningful values as the agent session's display label.
            state.$title.removeDuplicates().sink { [weak self] title in
                guard let self, let session = self.session(id) else { return }
                let cleaned = self.sanitizedLiveTitle(title)
                guard self.isMeaningfulLiveTitle(cleaned, for: session),
                      self.liveTitles[id] != cleaned else { return }
                self.liveTitles[id] = cleaned
            },
        ]
    }

    /// Strips a leading decorative glyph from a live title before it is shown.
    /// Claude Code prefixes its terminal title with a `✳` status star (and cycles
    /// it through spinner frames); since the sidebar row already draws the agent
    /// icon, that prefix would render as a duplicate icon. Drop any leading run of
    /// non-alphanumeric characters (the star, bullets, emoji) and the whitespace
    /// after it, leaving just the human-readable text.
    private func sanitizedLiveTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.drop { !$0.isLetter && !$0.isNumber }
        return String(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a live terminal title is worth showing as the session's label, as
    /// opposed to the startup noise we'd rather not flash. Only agent sessions
    /// adopt one (plain shells keep their `Terminal N` numbering), and even then
    /// we reject what agents/shells report before they have anything to say: an
    /// empty string, a bare path or `user@host`, or just the program's own name.
    private func isMeaningfulLiveTitle(_ title: String, for session: Session) -> Bool {
        guard session.agent != .terminal else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~"),
              !trimmed.contains("@") else { return false }
        let lowered = trimmed.lowercased()
        if lowered == session.agent.displayName.lowercased() { return false }
        if let command = session.command {
            let firstToken = command.split(separator: " ").first.map(String.init) ?? command
            if lowered == (firstToken as NSString).lastPathComponent.lowercased() { return false }
        }
        // Shells set the OSC title to the working-directory basename (e.g. "termio"),
        // and some agents prefix it with a brand glyph that survives sanitizing
        // because the glyph is a Unicode letter (Pi reports "π - termio"); either way
        // it names the folder, not the agent's activity, so it is not meaningful. Test
        // both the whole title and the segment after a " - " separator.
        let workingDirectory = session.worktreePath ?? project(for: session.id)?.path
        if let workingDirectory {
            let folder = (workingDirectory as NSString).lastPathComponent.lowercased()
            let tail = lowered.components(separatedBy: " - ").last ?? lowered
            if lowered == folder || tail == folder { return false }
        }
        return true
    }

    /// Brings up the hook socket and aligns `~/.claude/settings.json` with the
    /// current setting. The listener always runs (it is harmless when no hooks are
    /// installed); only the settings-file side is toggled.
    private func startHookMonitoring() {
        let listener = HookListener { [weak self] report in
            self?.applyStatusReport(report)
        }
        listener.start()
        hookListener = listener
        installedHooksEnabled = settings.agentHooksEnabled
        syncHooksInstallation()

        // A coarse 30s tick is plenty: the timeout it enforces is measured in
        // minutes, so this just needs to notice eventually.
        staleWorkingSweep = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepStaleWorking() }
        }
    }

    /// Re-aligns the installed hooks when, and only when, the hooks setting itself
    /// changed. Called from the shared settings observer, which fires for every
    /// preference, so the guard keeps unrelated changes from rewriting the file.
    private func syncHooksInstallationIfNeeded() {
        guard installedHooksEnabled != settings.agentHooksEnabled else { return }
        installedHooksEnabled = settings.agentHooksEnabled
        syncHooksInstallation()
    }

    private func syncHooksInstallation() {
        AgentStatusHooks.sync(enabled: settings.agentHooksEnabled)
    }

    /// Brings up the control socket and aligns the agents' awareness note with the
    /// current setting. Like the hook listener, the socket always runs; only the
    /// note written into the agent instruction files is toggled.
    private func startSessionControl() {
        let control = SessionControlListener { [weak self] request in
            self?.handleSessionControl(request) ?? Data()
        }
        control.start()
        sessionControl = control
        installedSessionControlEnabled = settings.sessionControlEnabled
        syncSessionControlInstallation()
    }

    private func syncSessionControlInstallationIfNeeded() {
        guard installedSessionControlEnabled != settings.sessionControlEnabled else { return }
        installedSessionControlEnabled = settings.sessionControlEnabled
        syncSessionControlInstallation()
    }

    private func syncSessionControlInstallation() {
        SessionSkillInstaller.sync(enabled: settings.sessionControlEnabled)
    }

    /// Maps a normalized agent status report onto the session's status. This is the
    /// only path that drives `.working`: an agent's hooks expose when a turn (or a
    /// tool) *starts*, which the surface bell/OSC signals never could. The two
    /// layers coexist by writing the same `statuses` — hooks add precision when
    /// installed, the zero-config signals remain the fallback when they are not.
    private func applyStatusReport(_ report: StatusReport) {
        guard let id = sessionID(for: report) else { return }
        switch report.state {
        case "working":
            // A plain terminal session has no agent turn to spin for: if an agent
            // run inside one (or a cwd-matched report from a sibling session) reports
            // working, leave it calm so only real agent rows show the thinking spinner.
            guard session(id)?.agent != .terminal else { break }
            statuses[id] = .working
            currentTool[id] = report.tool
            // Remember when work was last seen, so a turn that ends abnormally
            // (the agent crashed and never sent `done`) can be swept back to calm
            // instead of spinning forever — the failure mode cmux's own tracker
            // suffers from (issue #3749).
            lastWorkingAt[id] = Date()
        case "done":
            // The turn finished. If the user is looking at it, calm; otherwise a
            // gentle "ready for you" cue — distinct from `needsAttention`, which is
            // reserved for the agent actually being blocked on the user.
            clearWorking(id)
            statuses[id] = (selectedSessionID == id) ? .idle : .done
        case "attention":
            // The agent is blocked waiting on the user (a permission prompt or a
            // free-text answer). Mirror the bell path: only flag a session the user
            // isn't already looking at.
            clearWorking(id)
            if selectedSessionID != id { statuses[id] = .needsAttention }
        case "idle":
            clearWorking(id)
            statuses[id] = .idle
        default:
            break
        }
    }

    private func clearWorking(_ id: Session.ID) {
        currentTool[id] = nil
        lastWorkingAt[id] = nil
    }

    /// Sweeps sessions stuck in `.working` with no activity for a generous window
    /// back to `.idle`. This only matters while the user is looking elsewhere —
    /// selecting a session already clears it — so the timeout is long enough never
    /// to interrupt a genuinely long turn (tool events keep refreshing it), and is
    /// purely a recovery path for an agent that died mid-turn.
    private func sweepStaleWorking() {
        let now = Date()
        for (id, since) in lastWorkingAt where now.timeIntervalSince(since) > staleWorkingTimeout {
            if statuses[id] == .working { statuses[id] = .idle }
            clearWorking(id)
        }
    }

    /// Resolves a status report back to its session. The exact key is the
    /// `TERMIO_SESSION` id termio stamped into the PTY and the agent echoed back, so
    /// this is unambiguous even when several sessions share one project directory.
    /// `cwd` is only a fallback for an agent whose environment didn't carry the id
    /// through to the hook.
    private func sessionID(for report: StatusReport) -> Session.ID? {
        if let token = report.termioSession,
           let id = UUID(uuidString: token),
           session(id) != nil {
            return id
        }
        return sessionID(forCwd: report.cwd)
    }

    /// Fallback correlation by working directory, for a report that arrived without
    /// a usable session id. A session's worktree directory is unique, so a single
    /// match is exact; in a shared directory we don't guess and leave status alone.
    private func sessionID(forCwd cwd: String?) -> Session.ID? {
        guard let cwd else { return nil }
        let target = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let matches = projects.flatMap { project in
            project.sessions.filter { session in
                let directory = session.worktreePath ?? project.path
                return URL(fileURLWithPath: directory).standardizedFileURL.path == target
            }
        }
        guard matches.count == 1 else { return nil }
        return matches.first?.id
    }

    /// A short description of a session's current agent activity, for the sidebar
    /// status tooltip: the tool in use while working, or what it is waiting on.
    /// Empty when idle, so the tooltip simply does not appear.
    func statusDescription(for sessionID: Session.ID) -> String {
        switch status(for: sessionID) {
        case .idle:
            return ""
        case .working:
            if let tool = currentTool[sessionID] { return "Working — \(tool)" }
            return "Working…"
        case .done:
            return "Done"
        case .needsAttention:
            return "Waiting for you"
        }
    }

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

    /// Reorders the project list for the sidebar's drag-to-reorder. The new order
    /// persists through `projects`' `didSet`, so it survives a relaunch.
    func moveProject(fromOffsets source: IndexSet, toOffset destination: Int) {
        projects.move(fromOffsets: source, toOffset: destination)
    }

    /// Presents a folder picker and, on confirmation, opens the chosen directory
    /// as a new project. Shared by the sidebar's open-project button and the
    /// File ▸ Open… (⌘O) menu item so both routes run the same code. `runModal`
    /// is fine on the main actor — a modal file picker is expected to block.
    /// Presents the folder picker. `sandboxed` decides whether the opened project runs
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

    /// Removes a project from the sidebar: tears down every session's live surface
    /// (and its PTY) and drops the project from the tree. Only the sidebar entry is
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

    /// removed — the folder on disk, and any git worktrees the sessions created, are
    /// deliberately left untouched, the same hands-off stance `closeSession` takes
    /// (they may hold uncommitted agent work, so deletion is the user's call).
    func removeProject(_ id: Project.ID) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == id }) else { return }

        let removedSessionIDs = Set(projects[projectIndex].sessions.map(\.id))
        for sessionID in removedSessionIDs {
            SandboxLauncher.cleanUp(sessionID: sessionID)
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
}

/// Handles `termio sessions …` requests from `SessionControlListener`. Every
/// operation is scoped to the caller's own project (resolved from the caller's
/// `TERMIO_SESSION` or, failing that, its working directory) so an agent can only
/// see and drive its siblings, never sessions in unrelated projects — unpeel's
/// "project-scoped by default" rule.
extension TermioStore {
    func handleSessionControl(_ request: ControlRequest) -> Data {
        guard settings.sessionControlEnabled else {
            return controlError(request, "disabled",
                "Session control is off. Enable it in termio ▸ Settings ▸ Agents.")
        }
        guard let project = callerProject(session: request.callerSession, cwd: request.callerCwd) else {
            return controlError(request, "no_scope",
                "Couldn't tell which project you're in. Run this from inside a termio session.")
        }

        switch request.op {
        case "list": return listSessions(in: project, request: request)
        case "send", "answer": return sendText(request, in: project)
        case "start": return startSession(request, in: project)
        case "stop": return stopSession(request, in: project)
        case "read":
            return controlError(request, "read_unavailable",
                "Reading a session's output isn't available in this build yet — it needs a "
                + "terminal-core buffer API. list / send / answer / start / stop work today.")
        default:
            return controlError(request, "bad_op", "Unknown op '\(request.op)'.")
        }
    }

    private func listSessions(in project: Project, request: ControlRequest) -> Data {
        let entries = project.sessions.map { session -> [String: Any] in
            [
                "id": Self.shortID(session.id),
                "title": displayTitle(for: session),
                "agent": session.agent.displayName,
                "status": Self.statusToken(status(for: session.id)),
                "description": statusDescription(for: session.id),
            ]
        }
        let lines = project.sessions.map { session -> String in
            let token = Self.statusToken(status(for: session.id))
            let description = statusDescription(for: session.id)
            let suffix = description.isEmpty ? "" : "  — \(description)"
            return "\(Self.shortID(session.id))  [\(token)]  \(displayTitle(for: session)) "
                + "(\(session.agent.displayName))\(suffix)"
        }
        let header = "\(project.name) — \(project.sessions.count) session(s)"
        let text = ([header] + lines).joined(separator: "\n")
        return control(request, ok: true, text: text, json: ["project": project.name, "sessions": entries])
    }

    private func sendText(_ request: ControlRequest, in project: Project) -> Data {
        guard let payload = request.text, !payload.isEmpty else {
            return controlError(request, "no_text", "\(request.op) needs text to send.")
        }
        switch resolveTarget(request.target, in: project) {
        case .found(let session):
            // Get-or-create the surface so a prompt can be sent to a session that
            // hasn't been opened yet (this starts its shell, which is what we want).
            let surface = surface(for: session, in: project)
            // The carriage return submits the line, matching pressing Return.
            // `send` returns false when no live terminal is attached yet, so report
            // that honestly rather than claiming a prompt that went nowhere.
            guard surface.send(payload + "\r") else {
                return controlError(request, "not_live",
                    "\(displayTitle(for: session)) has no live terminal yet — open it once in termio.")
            }
            return control(request, ok: true,
                text: "sent to \(displayTitle(for: session))",
                json: ["target": Self.shortID(session.id), "title": displayTitle(for: session)])
        case .notFound:
            return controlError(request, "not_found", targetNotFoundMessage(request.target))
        case .ambiguous:
            return controlError(request, "ambiguous",
                "'\(request.target ?? "")' matches more than one session; use a longer id.")
        }
    }

    private func startSession(_ request: ControlRequest, in project: Project) -> Data {
        guard let preset = AgentPreset.resolve(request.agent) else {
            let names = AgentPreset.allCases.map(\.rawValue).joined(separator: ", ")
            return controlError(request, "bad_agent",
                "Unknown agent '\(request.agent ?? "")'. Try one of: \(names).")
        }
        addSession(to: project.id, agent: preset)
        guard let id = selectedSessionID, let session = self.session(id) else {
            return controlError(request, "start_failed", "Could not start the session.")
        }
        return control(request, ok: true,
            text: "started \(displayTitle(for: session)) (\(Self.shortID(id)))",
            json: ["id": Self.shortID(id), "title": displayTitle(for: session),
                   "agent": session.agent.displayName])
    }

    private func stopSession(_ request: ControlRequest, in project: Project) -> Data {
        switch resolveTarget(request.target, in: project) {
        case .found(let session):
            let title = displayTitle(for: session)
            closeSession(session.id)
            return control(request, ok: true, text: "stopped \(title)", json: ["title": title])
        case .notFound:
            return controlError(request, "not_found", targetNotFoundMessage(request.target))
        case .ambiguous:
            return controlError(request, "ambiguous",
                "'\(request.target ?? "")' matches more than one session; use a longer id.")
        }
    }

    /// Resolves the calling agent to its project: by the `TERMIO_SESSION` the PTY
    /// carries (exact), else by a working directory that sits inside a project's
    /// directory or one of its session worktrees (the fallback for a plain shell).
    private func callerProject(session id: String?, cwd: String?) -> Project? {
        if let id, let uuid = UUID(uuidString: id), let project = project(for: uuid) {
            return project
        }
        guard let cwd else { return nil }
        let target = URL(fileURLWithPath: cwd).standardizedFileURL.path
        func contains(_ directory: String) -> Bool {
            let base = URL(fileURLWithPath: directory).standardizedFileURL.path
            return target == base || target.hasPrefix(base + "/")
        }
        // A session worktree is the most specific match, so prefer it.
        for project in projects {
            for session in project.sessions where session.worktreePath.map(contains) == true {
                return project
            }
        }
        return projects.first { contains($0.path) }
    }

    private enum TargetResolution {
        case found(Session)
        case notFound
        case ambiguous
    }

    /// Matches a target token within the caller's project by full id, id prefix, or
    /// title (case-insensitive). Ambiguity is reported rather than guessed.
    private func resolveTarget(_ token: String?, in project: Project) -> TargetResolution {
        guard let token = token?.trimmingCharacters(in: .whitespaces).lowercased(), !token.isEmpty else {
            return .notFound
        }
        // Match the *displayed* title only, never the stored one: `list` shows the
        // display title (terminals are re-indexed live), so that's what an agent
        // references. The stored title is an internal worktree-slug seed and can
        // collide with another session's display title — matching it would make an
        // unambiguous name read as ambiguous.
        let matches = project.sessions.filter { session in
            let id = session.id.uuidString.lowercased()
            return id == token
                || id.hasPrefix(token)
                || displayTitle(for: session).lowercased() == token
        }
        switch matches.count {
        case 0: return .notFound
        case 1: return .found(matches[0])
        default: return .ambiguous
        }
    }

    private func targetNotFoundMessage(_ token: String?) -> String {
        "No session '\(token ?? "")' in this project. Run `termio sessions list` to see ids."
    }

    private func control(_ request: ControlRequest, ok: Bool, text: String, json: [String: Any]) -> Data {
        if request.wantsJSON {
            var object = json
            object["ok"] = ok
            let data = (try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return data + Data("\n".utf8)
        }
        return Data((text.hasSuffix("\n") ? text : text + "\n").utf8)
    }

    private func controlError(_ request: ControlRequest, _ code: String, _ message: String) -> Data {
        control(request, ok: false, text: "error: \(message)", json: ["error": code, "message": message])
    }

    private static func shortID(_ id: Session.ID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    private static func statusToken(_ status: SessionStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .working: return "working"
        case .done: return "done"
        case .needsAttention: return "needs-you"
        }
    }
}

/// The session tree's on-disk home: it owns the file location and the JSON
/// (de)serialization, so `TermioStore` only ever hands it values. Live state
/// (terminal surfaces, per-session activity) is intentionally never written —
/// shells restart fresh, so only the tree and the current selection persist.
private struct StateFile {
    struct Snapshot: Codable {
        var projects: [Project]
        var selectedSessionID: Session.ID?
    }

    let url = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        .map { $0.appendingPathComponent("termio", isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".termio", isDirectory: true)

    private var stateURL: URL { url.appendingPathComponent("state.json") }

    /// The saved snapshot, or `nil` on first launch or an unreadable/corrupt file
    /// (in which case the caller seeds fresh state rather than failing).
    func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Best-effort, atomic write. Failures are logged rather than crashing —
    /// losing a save is recoverable, trapping is not. Indented and key-sorted so
    /// the file reads like a config and diffs cleanly, not a one-line blob.
    func save(_ snapshot: Snapshot) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: stateURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("termio: failed to persist state: \(error)\n".utf8))
        }
    }
}
