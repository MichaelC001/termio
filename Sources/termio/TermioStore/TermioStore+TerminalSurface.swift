import Combine
import Foundation
import GhosttyTerminal
import GhosttyTheme

extension TermioStore {
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
