# termio

A native macOS terminal app for AI coding agents — a sidebar of projects, each
holding multiple live terminal sessions, rendered with **libghostty** (Ghostty's
terminal core) on Metal. No Electron/Chromium.

Modeled on [unpeel](https://unpeel.com/): projects → sessions in the sidebar,
each session a real PTY terminal running a shell or an agent (Claude Code /
Codex), with sessions grouped per project.

## Stack

- **Swift + AppKit/SwiftUI** for the UI shell.
- **[libghostty-spm](https://github.com/Lakr233/libghostty-spm)** (`GhosttyTerminal`)
  for the terminal surface. It ships a prebuilt `GhosttyKit.xcframework`, so no
  `zig` toolchain is needed to build termio.

## Build & run

```sh
swift build      # resolves libghostty-spm + compiles
swift run        # launches the app
```

Requires macOS 14+, Swift 6 (Xcode 26).

## Layout

| File | Role |
| --- | --- |
| `Sources/termio/App.swift` | `NSApplication` bootstrap, window, menu |
| `Sources/termio/Models.swift` | `Project` / `Session` model + seed data |
| `Sources/termio/TermioStore.swift` | state + per-session terminal **SurfaceCache** |
| `Sources/termio/RootView.swift` | `NavigationSplitView` (sidebar + detail) |
| `Sources/termio/SidebarView.swift` | projects → sessions, `+` to add a session, status dots |
| `Sources/termio/TerminalPane.swift` | top bar + `TerminalSurfaceView` |
| `Sources/termio/MenuBarController.swift` | menu-bar tray: pulse + session roster |

### How sessions persist

`TermioStore` caches one `TerminalViewState` per session id. Because libghostty's
`configureView` re-attaches the *same* `TerminalController` (which owns the
surface) instead of respawning, switching sessions in the sidebar keeps each
shell alive. This mirrors unpeel's `SurfaceCache`.

## Status

**Milestone 1 (done):** projects/sessions sidebar, a live `.exec` PTY terminal
per session in the project's working directory, session switching with
persistence, auto-title from the terminal title.

**Milestone 2 (done):** agent presets — the `+` next to a project opens a picker
(Terminal / Claude Code / Codex) and the chosen agent CLI launches in
that session. The terminal pane is chrome-free (no app header); when a session
runs an agent, the agent's own UI fills the pane and the native titlebar shows
`project ⌥ branch`. The sidebar row shows each session's agent glyph.

**Milestone 3 (done):** session status + menu-bar tray. Each session has a
`SessionStatus` (idle / working / needs-attention) shown as a sidebar dot and
aggregated into an `NSStatusItem` that stays calm, pulses while working, and
rings (amber bell) when a session wants you; its dropdown is a roster of every
session grouped by project, and picking one focuses it and brings the window
forward. Detection is zero-config: `TermioStore` observes the surface signals
`TerminalViewState` already publishes (`lastBellAt` / `lastDesktopNotificationAt`),
and Claude Code emits OSC 9/99 notifications natively inside Ghostty, so
"needs you" lights up with no per-agent setup.

**Next:**
- Per-turn **working** detection via Claude Code hooks (the surface exposes
  command-*finished* but not command-*start*, so continuous "thinking" needs the
  hooks layer — a localhost listener + `Stop`/`Notification`/`PreToolUse` hooks).
- Git worktrees grouped under each project (also gives each session a unique cwd,
  which is what lets hooks correlate back to the right session).
- Hosted PTY / session-host so sessions survive quitting the window.
