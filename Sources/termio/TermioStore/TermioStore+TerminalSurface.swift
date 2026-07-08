import Combine
import Foundation
import GhosttyTerminal
import GhosttyTheme

/// Looks up whether Claude Code has a saved conversation for a given session id.
/// Claude stores each conversation at `~/.claude/projects/<encoded-cwd>/<id>.jsonl`;
/// we glob across the project folders by id rather than reconstruct Claude's cwd
/// encoding (which is its private detail). Used to decide between `--session-id`
/// (create) and `--resume` (resume) — resuming an id with no saved conversation errors.
enum ClaudeConversation {
    static func exists(id: String) -> Bool { transcriptPath(id: id) != nil }

    /// The transcript file for a saved conversation `id`, or `nil` if none exists.
    /// Globs the project folders for `<id>.jsonl` rather than reconstructing Claude's
    /// cwd encoding. Because termio pins Claude's id (`Session.resumeID`) up front, this
    /// resolves a session's transcript directly — the fallback the Info pane uses when
    /// the hook never delivered a `transcript_path` (a session started before the
    /// transcript-capturing hook was installed; Claude reads hooks only at startup).
    static func transcriptPath(id: String) -> String? {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil) else { return nil }
        let transcript = "\(id).jsonl"
        for folder in folders {
            let candidate = folder.appendingPathComponent(transcript)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }
}

extension TermioStore {
    /// Returns the cached terminal surface for a session, creating and starting
    /// it on first access. The surface launches `session.command` (or the login
    /// shell) in the project's working directory via the real PTY (`.exec`).
    func surface(for session: Session, in project: Project) -> TerminalViewState {
        if let existing = surfaces[session.id] {
            return existing
        }

        // An isolated worktree (if one was created for this session) wins over the
        // project's own directory, so the agent edits the branch in place — and so the
        // sandbox's writable workspace is exactly where the session actually works.
        let workspacePath = session.worktreePath ?? project.path

        // Resolve the launch command *with* any resume arguments, so a session that was
        // running when the app last quit picks its conversation back up instead of
        // starting over. `resumeID` is the id we persist for it (nil for the plain shell
        // and the directory-resume agents); it's written back below.
        let launch = resolveLaunch(for: session, workspacePath: workspacePath)
        let agentCommand = launch.command

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
            applyAppearance(to: &builder)
        }
        let state = TerminalViewState(controller: controller)
        state.controller.setTheme(makeTheme())

        // Host-managed backend: termio owns the PTY (rather than libghostty's
        // `.exec`), so the byte stream can be teed to a phone and read for
        // session control. The surface's keystrokes/resizes flow to the PTY via
        // the callbacks; the PTY's output fans back into the surface (and any
        // attached companion sink) through `receive`.
        let effectiveCommand = sandboxedCommand ?? agentCommand
        let argv = Self.launchArgv(command: effectiveCommand)
        var env = Self.sanitizedEnvironment()
        // Stamp the session id so any agent hook running inside can echo it back,
        // letting `HookListener` correlate events to this exact session.
        env["TERMIO_SESSION"] = session.id.uuidString
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "termio"

        // The PTY is created first so the surface's `@Sendable` write/resize
        // callbacks can capture it directly (it is thread-safe: fd writes and
        // ioctl are atomic, sinks are lock-guarded).
        // Spawn at the last real host grid rather than a fixed 80×24, so the
        // shell's first prompt is drawn at (usually) the window's actual width
        // and the first layout pass doesn't reflow it — the reflow that mangles
        // zsh's `PROMPT_SP` line into a stray `%` (see `lastHostGridColumns`).
        let pty = PTYProcess(argv: argv, cwd: workspacePath, env: env,
                             cols: lastHostGridColumns, rows: lastHostGridRows)
        let inMemory = InMemoryTerminalSession(
            write: { data in
                // Typing on the Mac reclaims the winsize from an attached
                // phone — the size follows the device being used.
                pty?.claimHostOwnership()
                pty?.write(data)
            },
            resize: { [weak self] viewport in
                let columns = Int(viewport.columns)
                let rows = Int(viewport.rows)
                pty?.resizeFromHost(cols: columns, rows: rows)
                // Remember the host grid for the next session's initial size.
                DispatchQueue.main.async { self?.rememberHostGrid(columns: columns, rows: rows) }
            }
        )
        if let pty {
            pty.addSink { [weak inMemory] data in inMemory?.receive(data) }
            // Tap the same stream as a working-liveness signal: while an agent is
            // mid-turn its TUI repaints changing content (a ticking spinner,
            // streaming tokens), so a *changing* screen keeps `lastWorkingAt`
            // fresh and a screen that goes static lets the stale sweep clear the
            // spinner — the recovery path for a turn that ends without a `Stop`
            // hook. Liveness is judged on the rendered viewport, not raw bytes:
            // an agent parked at an idle prompt still dribbles output (a redraw, a
            // blinking cursor) that the byte stream alone reads as activity, which
            // is what pins a finished agent's spinner on forever. `readViewportText`
            // is thread-safe (its own lock), so the compare runs on the read pump;
            // only the changed-flag hops to the main actor. Throttled to once a
            // second and cheap when the session isn't spinning
            // (`noteOutputActivity` no-ops). The read pump calls sinks serially, so
            // the captured `lastPoke` / `lastScreenSignature` need no lock.
            // A user agent may declare `status` regex rules in its `agent.json`; the
            // same viewport read that feeds the liveness sweep is classified against
            // them to drive working / needs-attention / done for agents that ship no
            // hook system (see `AgentStatusRules`). Built-ins carry no rules (they use
            // hooks), so this is `nil` for them and the classify step is skipped.
            //
            // Caveat: `readViewportText` returns the *displayed* viewport, which follows
            // the user's scrollback — so scrolling an inline agent's pane up feeds stale
            // rows to the classifier until it snaps back to the bottom (self-healing).
            // herdr avoids this by reading the live bottom (active) buffer; the clean fix
            // here needs a `readActiveText()` on the libghostty wrapper (its blessed read
            // serializes against the PTY write under a private lock we can't hold, and a
            // raw unsynchronized `GHOSTTY_POINT_ACTIVE` read from this pump thread would
            // race `inMemory.receive` — the exact libghostty threading hazard termio has
            // been bitten by). Tracked as an upstream ask, not worked around unsafely.
            let statusRules = session.agent.statusRules
            let agentID = session.agent.id
            let statusTrace = ProcessInfo.processInfo.environment["TERMIO_STATUS_TRACE"] != nil
            var lastPoke = Date.distantPast
            var lastScreenSignature: Int?
            pty.addSink { [weak self, weak inMemory] _ in
                let now = Date()
                guard now.timeIntervalSince(lastPoke) >= 1 else { return }
                lastPoke = now
                let text = inMemory?.readViewportText()
                let screenChanged: Bool
                if let text {
                    let signature = text.hashValue
                    screenChanged = signature != lastScreenSignature
                    lastScreenSignature = signature
                } else {
                    // No surface to read (e.g. detached) — fall back to treating
                    // output as activity rather than risk clearing a live turn.
                    screenChanged = true
                }
                let detected: AgentStatusRules.Activity?
                if let statusRules {
                    let (activity, matched) = statusRules.explain(text ?? "")
                    detected = activity
                    if statusTrace {
                        AgentStatusRules.trace(
                            agent: agentID, session: session.id, activity: activity, matched: matched)
                    }
                } else {
                    detected = nil
                }
                DispatchQueue.main.async {
                    self?.noteOutputActivity(session.id, screenChanged: screenChanged)
                    if let detected {
                        self?.applyScreenDetectedActivity(detected, for: session.id)
                    }
                }
            }
            pty.onExit = { [weak self, weak inMemory] code in
                inMemory?.finish(exitCode: UInt32(bitPattern: code), runtimeMilliseconds: 0)
                self?.ptyProcesses[session.id] = nil
                self?.lastScreenActivity[session.id] = nil
            }
            ptyProcesses[session.id] = pty
        }

        state.configuration = TerminalSurfaceOptions(backend: .inMemory(inMemory))
        surfaces[session.id] = state
        monitor(state, for: session.id)
        warmUpRendering(state)
        // Record that this session has now launched (and its pinned resume id) so the
        // next app run resumes it — but on the *next* runloop turn, not inline. This
        // method is called from `TerminalPane`'s `body`, and `recordLaunch` writes the
        // `@Published projects` tree; mutating published state mid-render re-enters
        // SwiftUI's view-graph transaction and aborts the app (an AttributeGraph
        // `precondition_failure` during `NSHostingView.layout`). The surface is already
        // cached above, so the re-render this schedules just looks it up and returns
        // (no second shell), and `recordLaunch` is idempotent — running it a turn later
        // is harmless. (`surfaces`/`monitors` are plain, non-`@Published` caches, so
        // writing them here is fine; only the `projects` write must be deferred.)
        DispatchQueue.main.async { [self] in recordLaunch(session.id, resumeID: launch.resumeID) }
        return state
    }

    /// The app's environment minus identity claims that belong to whatever launched
    /// it, not to the sessions it hosts. When termio is relaunched from a terminal
    /// (a dev rebuild out of VS Code, or an agent session), the child agent would
    /// otherwise detect the *host's* terminal (`TERM_PROGRAM=vscode`) or believe it
    /// is a nested Claude Code run (`CLAUDECODE`, `CLAUDE_CODE_SSE_PORT`, …). termio
    /// is the terminal here, so none of those claims may reach the session. A
    /// Finder launch carries none of them — this only matters for dev relaunches.
    private static func sanitizedEnvironment() -> [String: String] {
        let dropped: Set<String> = [
            "CLAUDECODE", "CLAUDE_EFFORT", "TERM_SESSION_ID", "TERMINAL_EMULATOR",
            "TMUX", "TMUX_PANE", "STY", "INSIDE_EMACS", "LC_TERMINAL",
            "LC_TERMINAL_VERSION", "KONSOLE_VERSION", "GNOME_TERMINAL_SERVICE",
            "WT_SESSION",
        ]
        let droppedPrefixes = [
            "TERM_PROGRAM", "VSCODE_", "CLAUDE_CODE_", "ITERM_", "GHOSTTY_",
            "KITTY_", "WEZTERM_", "ALACRITTY_",
        ]
        return ProcessInfo.processInfo.environment.filter { key, _ in
            !dropped.contains(key) && !droppedPrefixes.contains { key.hasPrefix($0) }
        }
    }

    /// The argv to spawn in the session's PTY. An agent command string (possibly
    /// a full sandbox-exec line) runs through the shell so its quoting/args parse
    /// exactly as under libghostty's `.exec`; `exec` keeps the shell from lingering
    /// as an extra process. A `nil` command is the plain interactive login shell.
    private static func launchArgv(command: String?) -> [String] {
        if let command, !command.isEmpty {
            return ["/bin/sh", "-c", "exec \(command)"]
        }
        let loginShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return [loginShell, "-il"]
    }

    /// The launch command for a session, with resume arguments folded in, plus the
    /// resume id that should be persisted for it (nil when the agent doesn't pin one).
    /// Pure — it reads session state but mutates nothing; `recordLaunch` does the write.
    private func resolveLaunch(for session: Session, workspacePath: String)
        -> (command: String?, resumeID: String?) {
        guard let base = settings.command(for: session.agent) else {
            return (nil, nil) // plain login shell — nothing to resume
        }
        let agent = session.agent
        let resumeID: String?
        if agent.usesPinnedResumeID {
            // We mint and pin the id up front; reuse the persisted one across launches.
            resumeID = session.resumeID ?? UUID().uuidString
        } else if agent.usesDiscoveredResumeID, session.launched {
            // The id couldn't be set up front, so once the agent has run we learn it from
            // the agent's own session store — cached after the first successful discovery
            // so the scan happens at most once per session.
            resumeID = session.resumeID
                ?? AgentSessionStore.discover(agent: agent, directory: workspacePath,
                                              after: session.launchedAt)
        } else {
            resumeID = nil
        }
        let context = AgentPreset.ResumeContext(
            resumeID: resumeID ?? "",
            launchedBefore: session.launched,
            pinnedConversationExists: agent == .claudeCode
                && resumeID.map(ClaudeConversation.exists) == true
        )
        guard let arguments = agent.resumeArguments(context) else {
            return (base, resumeID)
        }
        return ("\(base) \(arguments)", resumeID)
    }

    /// Persists that a session has launched and, for the id-pinning agents, the id it
    /// was pinned to. Writes only when something actually changed, so re-opening an
    /// already-launched session doesn't churn the state file or re-sync watched folders.
    private func recordLaunch(_ id: Session.ID, resumeID: String?) {
        guard let location = locate(id) else { return }
        var session = projects[location.project].sessions[location.session]
        let firstLaunch = !session.launched
        let needsResumeID = resumeID != nil && session.resumeID == nil
        guard firstLaunch || needsResumeID else { return }
        if needsResumeID { session.resumeID = resumeID }
        if firstLaunch {
            session.launched = true
            // Stamp the launch moment so a later run can correlate Codex/OpenCode's own
            // session record back to this session by creation time (see `resolveLaunch`).
            session.launchedAt = Date()
        }
        projects[location.project].sessions[location.session] = session
    }

    /// The position of a session in the project tree, for an in-place edit.
    private func locate(_ id: Session.ID) -> (project: Int, session: Int)? {
        for (p, project) in projects.enumerated() {
            if let s = project.sessions.firstIndex(where: { $0.id == id }) {
                return (p, s)
            }
        }
        return nil
    }

    /// Pushes the current font and theme onto every live surface without tearing
    /// down its shell — libghostty reconfigures the running terminal in place.
    ///
    /// Reconfiguring updates the core's config but does not itself repaint: this
    /// embedding has no continuous tick (see `warmUpRendering`), so a surface only
    /// redraws on its next PTY-output wakeup. Without a nudge a theme or font change
    /// would not show until the user typed or the agent printed. So when a setter
    /// reports an actual change, pump the core briefly to flush the redraw now.
    func applyAppearanceToOpenSurfaces() {
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
            MainActor.assumeIsolated {
                guard let state else { timer.invalidate(); return }
                state.controller.tick()
                let elapsed = Date().timeIntervalSince(started)
                if (state.surfaceSize != nil && elapsed > 2.0) || elapsed > 6.0 {
                    timer.invalidate()
                }
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

    /// Drives `ghostty_app_tick` at display rate for a short window so a config
    /// change (theme, font, padding) repaints the live surface immediately, rather
    /// than waiting for the next PTY-output wakeup. A fixed short pump is enough: a
    /// color/font reconfigure needs no reply-gated handshake the way a cold spawn
    /// does, so a handful of frames flush the new look.
    private func pumpRendering(_ state: TerminalViewState, duration: TimeInterval) {
        let started = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak state] timer in
            MainActor.assumeIsolated {
                guard let state else { timer.invalidate(); return }
                state.controller.tick()
                if Date().timeIntervalSince(started) > duration {
                    timer.invalidate()
                }
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
                // Also record it on the session itself, so the label survives an
                // app restart (the agent won't re-emit a title until it next works).
                if let location = self.locate(id) {
                    self.projects[location.project].sessions[location.session]
                        .liveTitle = cleaned
                }
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
}
