# termio

A native macOS terminal app for AI coding agents — a sidebar of projects, each
holding multiple live terminal sessions, rendered with **libghostty** (Ghostty's
terminal core) on Metal. No Electron/Chromium.

Modeled on [unpeel](https://unpeel.com/): projects → sessions in the sidebar,
each session a real PTY terminal running a shell or an agent (Claude Code /
Codex / Gemini), with sessions grouped per project.

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
| `Sources/termio/SidebarView.swift` | projects → sessions, `+` to add a session |
| `Sources/termio/TerminalPane.swift` | top bar + `TerminalSurfaceView` |

### How sessions persist

`TermioStore` caches one `TerminalViewState` per session id. Because libghostty's
`configureView` re-attaches the *same* `TerminalController` (which owns the
surface) instead of respawning, switching sessions in the sidebar keeps each
shell alive. This mirrors unpeel's `SurfaceCache`.

## Status

**Milestone 1 (done):** projects/sessions sidebar, a live `.exec` PTY terminal
per session in the project's working directory, session switching with
persistence, auto-title from the terminal title.

**Next:**
- Model presets — launch `claude` / `codex` / `gemini` with the right flags per
  session (the `Session.command` field is already plumbed through).
- Git worktrees grouped under each project.
- Menu-bar pulse (spin when an agent is working, ring on bell —
  `TerminalViewState.bellCount` / `lastBellAt` are available).
- Hosted PTY / session-host so sessions survive quitting the window.

## History

termio was previously a Zed fork. On 2026-06-26 it was restarted from scratch as
a Swift + libghostty app. The Zed-fork tree is preserved in git history under the
`zed-fork-archive` tag (`git checkout zed-fork-archive`).
