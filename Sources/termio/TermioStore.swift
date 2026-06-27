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
            persist()
        }
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
        stateFile.save(.init(projects: projects, selectedSessionID: selectedSessionID))
    }

    func status(for sessionID: Session.ID) -> SessionStatus {
        statuses[sessionID] ?? .idle
    }

    /// The label to show for a session: the name the user gave it. The running
    /// program's live terminal title (`OSC 0/2`) is deliberately ignored here so
    /// the session keeps the label you assigned instead of being renamed to
    /// whatever the program reports when it starts. Centralized so the sidebar
    /// and the menu-bar tray always agree on what a session is called.
    func displayTitle(for session: Session) -> String {
        session.title
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

        builder.withWindowPaddingX(settings.windowPadding)
        builder.withWindowPaddingY(settings.windowPadding)
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
        let title = agent == .terminal
            ? "Terminal \(project.sessions.count + 1)"
            : agent.displayName
        var session = Session(title: title, agent: agent)
        session.worktreePath = makeWorktree(for: session, in: project)
        projects[index].sessions.append(session)
        selectedSessionID = session.id
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
