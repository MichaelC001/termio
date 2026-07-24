# termio — project guidelines

termio is a **native macOS terminal app for AI coding agents**, built with
**Swift + AppKit/SwiftUI** and the **libghostty** terminal core (via the
`libghostty-spm` package, product `GhosttyTerminal`). It is modeled on
unpeel.com. See `README.md` for architecture.

This is a deliberate, minimal, focused tool. Keep the surface area small; prefer
clarity over cleverness. Do not add features that were not requested.

## Swift conventions

- Prioritize correctness and clarity over micro-optimization.
- Avoid force-unwraps (`!`) and anything that traps. Use `guard let` / `if let`,
  and surface failures rather than crashing.
- Never silently discard errors. Handle them, log them, or propagate them.
- Comments explain *why*, not *what*. No summary/organizational comments.
- Use full words for names (no abbreviations).
- Prefer adding to existing files over creating many small ones; create a new
  file only for a genuinely new component.

## libghostty / GhosttyTerminal notes

- The package ships a prebuilt `GhosttyKit.xcframework`. **Do not** try to build
  Ghostty from source — `zig` is not installed.
- Terminal backends: `.exec` runs a real PTY inside ghostty; `.inMemory` is
  host-managed. termio uses **`.inMemory`**: it owns the PTY itself via
  `Sources/termio/Terminal/Ghostty/PTYProcess.swift` (spawned with `forkpty` — login_tty shape;
  do NOT switch to `posix_spawn`, that shape breaks agents' resize repaint, see
  `docs/bug/terminal-resize-no-reflow-HANDOFF.md`), and the surface only renders.
- One `TerminalViewState` owns one terminal surface via its `TerminalController`.
  Keep it alive (see `TermioStore` SurfaceCache) to keep the shell running across
  view rebuilds — `configureView` reattaches the same controller's surface.
- Per-session program: set it on the controller builder via
  `builder.withCustom("command", "...")` (the `Session.command` field feeds this).

## Build

```sh
swift build
swift run
```

Run from the macOS GUI session (it is a real foreground AppKit app). The app is
driven via an explicit `NSApplication` in `App.swift` rather than the SwiftUI
`App` lifecycle so a plain SwiftPM executable activates correctly.

## Git

- The pre-rewrite Zed fork is preserved under the `zed-fork-archive` tag.
- Commit or push only when the user asks.
- PR titles: imperative, correctly capitalized, no conventional-commit prefixes,
  no trailing punctuation. Include a `Release Notes:` section.
