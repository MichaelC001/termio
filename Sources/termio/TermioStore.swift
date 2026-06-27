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
        // edited) is written back to disk so the sidebar survives app restarts.
        didSet { persist() }
    }
    @Published var selectedSessionID: Session.ID? {
        // Selecting a session means the user is now looking at it, so any pending
        // "needs attention" is, by definition, answered.
        didSet {
            if let id = selectedSessionID {
                statuses[id] = .idle
            }
            // A split shows exactly its two sessions. Navigating to a session that
            // isn't one of them means the user has left the split, so collapse it
            // back to a single pane. Refocusing one of the two panes keeps it.
            if let split = splitSessionIDs, let id = selectedSessionID, !split.contains(id) {
                splitSessionIDs = nil
            }
            persist()
        }
    }

    /// The two sessions shown side by side, left-to-right, or `nil` for the normal
    /// single-pane view. `selectedSessionID` is always one of the two while a split
    /// is active and marks the focused pane.
    @Published var splitSessionIDs: [Session.ID]? {
        didSet { persist() }
    }

    /// Per-session activity, driven by the surface signals monitored below. A
    /// session with no entry (never opened, so no surface yet) reads as `.idle`.
    @Published private(set) var statuses: [Session.ID: SessionStatus] = [:]

    /// User preferences (appearance, agent commands, worktree behaviour). Held so
    /// surfaces can be configured on creation and re-styled live when settings
    /// change; also handed to the settings UI and sidebar.
    let settings: AppSettings

    private var surfaces: [Session.ID: TerminalViewState] = [:]
    private var monitors: [Session.ID: [AnyCancellable]] = [:]
    private var settingsObserver: AnyCancellable?
    private let stateFile = StateFile()

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
            .sink { [weak self] in self?.applyAppearanceToOpenSurfaces() }
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
        // Restore a split only if both panes still resolve to live sessions and the
        // focused session is one of them, so a stale snapshot can't leave the view
        // pointing at a session that no longer exists.
        if let split = snapshot.splitSessionIDs, split.count == 2,
           split.allSatisfy({ store.session($0) != nil }),
           let selected = store.selectedSessionID, split.contains(selected) {
            store.splitSessionIDs = split
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
            selectedSessionID: selectedSessionID,
            splitSessionIDs: splitSessionIDs
        ))
    }

    /// Whether a split is currently shown (exactly two panes).
    var isSplit: Bool { splitSessionIDs?.count == 2 }

    /// Whether a session is currently on screen: either pane of an active split,
    /// or the selected session in single-pane mode. Drives the sidebar highlight so
    /// both panes of a split read as live.
    func isShown(_ id: Session.ID) -> Bool {
        if let split = splitSessionIDs { return split.contains(id) }
        return selectedSessionID == id
    }

    /// Toggles the split: collapses it if active, otherwise pairs the focused
    /// session with a companion. A no-op when there is no second session to show.
    func toggleSplit() {
        if splitSessionIDs != nil {
            splitSessionIDs = nil
            return
        }
        guard let primary = selectedSessionID,
              let companion = defaultCompanion(for: primary) else { return }
        splitSessionIDs = [primary, companion]
    }

    /// Shows `id` in a split beside the focused session and moves focus to it. Only
    /// a plain terminal can be pulled into a split — agents stay dedicated full
    /// views, so an agent is never a split pane. The focused session it pairs beside
    /// may be anything, so a terminal can be split in even while an agent is on
    /// screen. With no distinct focused session to pair against, it just selects.
    func openInSplit(_ id: Session.ID) {
        guard session(id)?.agent == .terminal else { return }
        guard let primary = selectedSessionID, primary != id else {
            selectedSessionID = id
            return
        }
        splitSessionIDs = [primary, id]
        selectedSessionID = id
    }

    /// The terminal to pair with `primary` when splitting: the next plain terminal
    /// in the same project (then the previous), else any other open terminal. Agents
    /// are skipped, since only terminals are shown as split panes.
    private func defaultCompanion(for primary: Session.ID) -> Session.ID? {
        if let project = project(for: primary),
           let index = project.sessions.firstIndex(where: { $0.id == primary }) {
            if let next = project.sessions[(index + 1)...].first(where: { $0.agent == .terminal })
                ?? project.sessions[..<index].reversed().first(where: { $0.agent == .terminal }) {
                return next.id
            }
        }
        return projects.flatMap(\.sessions).first { $0.id != primary && $0.agent == .terminal }?.id
    }

    func status(for sessionID: Session.ID) -> SessionStatus {
        statuses[sessionID] ?? .idle
    }

    /// The label to show for a session. The running program's live terminal title
    /// (`OSC 0/2`) is deliberately ignored here so the session keeps its assigned
    /// label instead of being renamed to whatever the program reports on launch.
    ///
    /// Auto-named terminals (`Terminal N`) are re-indexed live by their position
    /// among the terminals in their project, so the list always reads 1, 2, 3…
    /// with no gaps or duplicates as sessions are added and removed. The stored
    /// title is left untouched (it seeds the worktree branch slug, which must stay
    /// stable); only the displayed number is recomputed. A title the user set to
    /// anything other than the `Terminal N` form is shown verbatim. Centralized so
    /// the sidebar and the menu-bar tray always agree on what a session is called.
    func displayTitle(for session: Session) -> String {
        guard session.agent == .terminal,
              Self.isAutoTerminalName(session.title),
              let project = project(for: session.id) else {
            return session.title
        }
        let terminals = project.sessions.filter { $0.agent == .terminal }
        guard let index = terminals.firstIndex(where: { $0.id == session.id }) else {
            return session.title
        }
        return "Terminal \(index + 1)"
    }

    /// Whether `title` is an auto-generated `Terminal N` label (as opposed to a
    /// name the user chose), which is what makes it eligible for live re-indexing.
    private static func isAutoTerminalName(_ title: String) -> Bool {
        let suffix = title.dropFirst("Terminal ".count)
        return title.hasPrefix("Terminal ") && !suffix.isEmpty
            && suffix.allSatisfy(\.isNumber)
    }

    /// The single state the menu-bar pulse renders: any session waiting on the
    /// user wins, otherwise any working session, otherwise calm.
    var aggregateStatus: SessionStatus {
        let all = projects.flatMap(\.sessions).map { status(for: $0.id) }
        if all.contains(.needsAttention) { return .needsAttention }
        if all.contains(.working) { return .working }
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

        let command = settings.command(for: session.agent)
        let controller = TerminalController { [self] builder in
            if let command {
                builder.withCustom("command", command)
            }
            applyAppearance(to: &builder)
        }
        let state = TerminalViewState(controller: controller)
        if let theme = makeTheme() {
            state.controller.setTheme(theme)
        }
        state.configuration = TerminalSurfaceOptions(
            backend: .exec,
            // An isolated worktree (if one was created for this session) wins over
            // the project's own directory, so the agent edits the branch in place.
            workingDirectory: session.worktreePath ?? project.path
        )
        surfaces[session.id] = state
        monitor(state, for: session.id)
        return state
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

    /// The selected Ghostty theme, or `nil` to leave the terminal core's default
    /// colors in place (when no theme is chosen or the name no longer resolves).
    private func makeTheme() -> TerminalTheme? {
        guard !settings.themeName.isEmpty,
              let definition = GhosttyThemeCatalog.theme(named: settings.themeName)
        else { return nil }
        return definition.toTerminalTheme()
    }

    /// Pushes the current font and theme onto every live surface without tearing
    /// down its shell — libghostty reconfigures the running terminal in place.
    private func applyAppearanceToOpenSurfaces() {
        let appearance = appearanceConfiguration()
        let theme = makeTheme()
        for state in surfaces.values {
            state.controller.setTerminalConfiguration(appearance)
            if let theme {
                state.controller.setTheme(theme)
            }
        }
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
        ]
    }

    func addSession(to projectID: Project.ID, agent: AgentPreset = .terminal) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let project = projects[index]
        let terminalCount = project.sessions.filter { $0.agent == .terminal }.count
        let title = agent == .terminal
            ? "Terminal \(terminalCount + 1)"
            : agent.displayName
        var session = Session(title: title, agent: agent)
        session.worktreePath = makeWorktree(for: session, in: project)
        projects[index].sessions.append(session)
        selectedSessionID = session.id
    }

    /// Presents a folder picker and, on confirmation, opens the chosen directory
    /// as a new project. Shared by the sidebar's open-project button and the
    /// File ▸ Open… (⌘O) menu item so both routes run the same code. `runModal`
    /// is fine on the main actor — a modal file picker is expected to block.
    func presentOpenProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a project folder to open in termio."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addProject(at: url)
    }

    /// Adds the directory at `url` as a new project section seeded with a single
    /// terminal session, which becomes the selection. A folder already open as a
    /// project is not duplicated — its first session is selected instead.
    func addProject(at url: URL) {
        let path = url.standardizedFileURL.path
        if let existing = projects.first(where: { $0.path == path }) {
            selectedSessionID = existing.sessions.first?.id
            return
        }
        let session = Session(title: "Terminal 1")
        var project = Project(
            name: url.lastPathComponent,
            path: path,
            branch: currentBranch(in: path) ?? "—",
            sessions: [session]
        )
        // Seed the first session exactly as addSession would, so a new project's
        // session behaves identically to one added to an existing project.
        project.sessions[0].worktreePath = makeWorktree(for: session, in: project)
        projects.append(project)
        selectedSessionID = project.sessions.first?.id
    }

    /// The checked-out branch of the git repository at `directory`, or `nil` when
    /// it is not a repo (rendered as "—", matching the seed projects).
    private func currentBranch(in directory: String) -> String? {
        runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
    }

    /// Creates an isolated git worktree for a new session, returning its absolute
    /// path, or `nil` to run the session directly in the project directory.
    /// Worktrees are a best-effort convenience: anything that prevents creation
    /// (worktrees disabled, not a git repo, a git failure) is logged and degrades
    /// gracefully — never a crash, per the project's no-trap rule.
    private func makeWorktree(for session: Session, in project: Project) -> String? {
        guard settings.worktreeEnabled else { return nil }
        guard runGit(["rev-parse", "--is-inside-work-tree"], in: project.path) != nil else {
            logWorktree("skipped: \(project.path) is not a git repository")
            return nil
        }

        let slug = Self.slug(session.title)
        let base = resolvedWorktreeBase(for: project)
        var directory = base.appendingPathComponent(slug).path
        var branch = settings.worktreeBranchPrefix + slug
        // Avoid clobbering an existing branch or directory (e.g. two sessions with
        // the same title) by disambiguating with a short slice of the session id.
        if branchExists(branch, in: project.path) || FileManager.default.fileExists(atPath: directory) {
            let suffix = String(session.id.uuidString.prefix(6)).lowercased()
            directory += "-" + suffix
            branch += "-" + suffix
        }

        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            logWorktree("could not create base directory \(base.path): \(error)")
            return nil
        }
        guard runGit(["worktree", "add", directory, "-b", branch], in: project.path) != nil else {
            logWorktree("git worktree add failed for \(directory)")
            return nil
        }
        return directory
    }

    private func resolvedWorktreeBase(for project: Project) -> URL {
        let raw = settings.worktreeBaseDirectory
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return URL(fileURLWithPath: project.path, isDirectory: true)
            .appendingPathComponent(raw, isDirectory: true)
            .standardizedFileURL
    }

    private func branchExists(_ branch: String, in directory: String) -> Bool {
        runGit(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: directory) != nil
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
            logWorktree("git could not be launched: \(error)")
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func logWorktree(_ message: String) {
        FileHandle.standardError.write(Data("termio: worktree \(message)\n".utf8))
    }

    /// Lowercased, hyphen-joined slug of a session title, safe for a branch name
    /// and a directory name.
    private static func slug(_ title: String) -> String {
        let mapped = title.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "session" : collapsed
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
        surfaces[id] = nil
        monitors[id] = nil
        statuses[id] = nil

        // A closed session can't stay in a split; losing either pane collapses the
        // split back to a single view of whatever remains.
        if let split = splitSessionIDs, split.contains(id) {
            splitSessionIDs = nil
        }

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

/// The session tree's on-disk home: it owns the file location and the JSON
/// (de)serialization, so `TermioStore` only ever hands it values. Live state
/// (terminal surfaces, per-session activity) is intentionally never written —
/// shells restart fresh, so only the tree and the current selection persist.
private struct StateFile {
    struct Snapshot: Codable {
        var projects: [Project]
        var selectedSessionID: Session.ID?
        var splitSessionIDs: [Session.ID]?
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
