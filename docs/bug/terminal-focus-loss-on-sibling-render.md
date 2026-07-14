---
title: Terminal loses focus while the window stays key — sibling-render trigger
status: fixed
type: bug
created: 2026-07-14
updated: 2026-07-14
related:
  - terminal-focus-loss-on-window-key.md
  - terminal-focus-loss-on-new-session-mount.md
---

# Terminal loses focus while the window stays key — sibling-render trigger

## Symptom

While typing in a terminal or agent TUI, another session changing state can make
the active cursor turn hollow. The main window remains key and the selected pane
does not change, but keystrokes have no destination until the user clicks.

## Why the first rescue did not work

All mounted terminal surfaces previously shared one optional SwiftUI focus value:

```swift
@FocusState private var focusedSession: Session.ID?
```

The first attempted repair watched that value change to `nil` and wrote the
selected session id back. Live tracing disproved its premise: clicking the
terminal can make Ghostty's `AppTerminalView` first responder (and its cursor
solid) without ever populating the SwiftUI value. `focusedSession` was already
`nil`, so there was no `value -> nil` transition and the repair was dead code.

The cursor's truth is AppKit first-responder ownership, which drives
`AppTerminalView.becomeFirstResponder` / `resignFirstResponder` and
`core.setFocus`. A shared `@FocusState` is only declarative intent, and was not a
reliable observation of that truth.

The shared optional also allowed cross-talk. Any mounted surface reporting
`false` wrote `nil` through `TerminalFocusBinding.optional`, clearing the intent
for every sibling. The wrapper's `synchronizeFocus` only focuses a view whose
binding already reads true, so nothing recovered from that state.

## Ghostty's model

Ghostty's macOS app uses three defenses that the wrapper integration lacked:

1. Every surface owns its own Boolean focus state; surfaces do not share an
   optional enum binding.
2. Window-key status is a separate axis and never becomes surface-focus truth.
3. `Ghostty.moveFocus` retries with a capped exponential backoff until the target
   view has a window, and explicitly resigns the previously focused surface before
   moving first responder.

Ghostty also remembers the last focused surface as a fallback during transient
SwiftUI focus gaps.

## Fix

`TerminalPane.swift` now adopts the parts of that model possible without rebuilding
the wrapper fork:

- `ManagedTerminalSurface` gives every mounted terminal its own
  `@FocusState<Bool>`. The binding is used to turn a click on a visible split into
  selection; it is not treated as the focus source of truth.
- `TerminalFocusDriver` locates the exact `GhosttyTerminal.TerminalView` in the
  main window by matching its `TerminalViewState` delegate. It moves AppKit first
  responder directly, explicitly resigns a previous terminal, and retries
  `50ms -> 100ms -> ... -> 500ms` while the selected view is not windowed.
- Selection changes, surface mount, palette/overlay close, file drop, and main
  window activation request focus explicitly.
- A small `NSViewRepresentable` probe gets `updateNSView` during parent/store
  reconciliation. On the following runloop it asks the driver to repair focus.
  Render-driven repair is guarded to the orphan shape (`firstResponder` is the
  window itself or `nil`), so it never steals focus from a field, overlay, browser,
  or newly clicked sibling.

The sibling-render path no longer depends on a shared FocusState transition or on
a single wrapper re-render landing at the right time.

## Deterministic verification

The dev command palette keeps **Debug: Orphan Terminal Focus**, but the injector
is now faithful. After the palette closes it finds the selected terminal's real
AppKit view, makes that view first responder, then calls
`window.makeFirstResponder(nil)` while the main window remains key. It does not
mutate SwiftUI focus state directly.

Expected focus-category log sequence:

```text
fault injector: dropped terminal first responder while key=true session=...
recovered terminal focus [fault-injector] -> ...
```

Read info/debug messages explicitly:

```sh
/usr/bin/log stream --level debug \
  --predicate 'subsystem == "sh.termio.app.dev" && category == "focus"'
```

The visual pass condition is that the cursor returns to solid and typing lands
without a click. macOS Accessibility/TCC prevents the shell from synthesizing the
verification keystroke, so the final visual/input check must be performed by a
person.

## Upstream

The wrapper should ultimately expose this as its own per-surface `moveFocus`
implementation so every host gets the same behavior. The app-side driver uses
only public wrapper APIs and the prebuilt Ghostty core, avoiding the Zig 0.15 /
macOS Tahoe fork-rebuild deadlock on this machine.
