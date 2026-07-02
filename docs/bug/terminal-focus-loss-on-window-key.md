---
title: Terminal randomly loses keyboard focus (hollow cursor) after window deactivation
status: active
type: bug
created: 2026-07-02
updated: 2026-07-02
---

# Terminal randomly loses keyboard focus (hollow cursor) after window deactivation

> Document the intermittent "cursor goes hollow, keystrokes go nowhere, must
> click to refocus" bug — a libghostty-spm focus-plumbing flaw amplified by
> termio's constant background re-renders — and the app-side rescue that fixes it.

## Symptom

While using the app, the terminal sometimes drops keyboard focus on its own:
the block cursor turns into a hollow outline (the terminal's "unfocused" state)
and typing goes nowhere until the user clicks the terminal to refocus. It feels
random — most window switches are fine, then one isn't.

## Root cause

`TerminalPane` binds terminal focus to a SwiftUI `@FocusState`
(`focusedSession`, `TerminalPane.swift`) via the package's `.terminalFocused`
modifier. Three pieces of **libghostty-spm** (Lakr233's package, v1.2.x)
interact badly with that binding:

1. **Window deactivation clears the SwiftUI binding.**
   `AppTerminalView+Lifecycle.swift:109` — when the main window resigns *key*
   (⌘-Tab, Spotlight, the menu-bar tray, Settings, a Sparkle dialog…),
   `windowDidResignKey` fires `onFocusChange?(false)`, which writes through
   `TerminalFocusBinding.optional` and sets `focusedSession = nil`
   (`TerminalViewRepresentable.swift:89-91`). This conflates two different
   things: losing key-window status is not losing in-window focus.

2. **Any re-render while non-key strips first responder.**
   `updateNSView` runs `synchronizeFocus` on every SwiftUI update
   (`TerminalViewRepresentable@AppKit.swift:28`). With the binding now reading
   false and the terminal still first responder, it calls
   `window.makeFirstResponder(nil)` (`TerminalViewRepresentable.swift:55-57`).
   termio re-renders constantly even when idle — `TerminalPane` observes
   `TermioStore`, whose `statuses` / `currentTool` / `liveTitles` /
   `liveActivity` / `gitChangeCount` update from agent hooks and git polling —
   so a store update landing while the window is non-key strips the terminal.

3. **Nothing restores focus on reactivation.**
   `windowDidBecomeKey` (`AppTerminalView+Lifecycle.swift:102`) only re-asserts
   focus if `window.firstResponder === self` — but first responder is now the
   window itself, so it does nothing. termio had no window-activation handler
   of its own; `focusedSession` was only re-set on session switch or overlay
   close. Result: hollow cursor until the user clicks.

### Why it feels random

If no store update happens to land during the non-key interval, step 2 never
runs: AppKit keeps the view as first responder and step 3 restores focus fine.
The bug bites only when background activity (an agent working, git polling)
coincides with the window being non-key — hence "sometimes", and more often
when agents are busy.

## Fix (app-side rescue, shipped)

`TerminalPane.swift` — a `NSWindow.didBecomeKeyNotification` observer
re-asserts `focusedSession = store.selectedSessionID`, guarded so it fires
**only in the exact orphaned state the bug produces**:

- the notification is for the **main window** (matched via
  `AppDelegate.mainWindowFrameAutosaveName`, hoisted in `App.swift` so the
  Settings window never triggers it);
- `window.firstResponder === window` (or nil) — first responder fell back to
  the window itself, which is what `makeFirstResponder(nil)` leaves behind and
  which no legitimate focus owner ever exhibits across a key-window cycle;
- no file / diff / trace overlay is open (those manage their own focus).

Safety property: any legitimate first responder (an overlay's text view, a
toolbar field) survives key-window cycles, so the guard fails and the rescue is
a no-op — it can never steal focus, and worst case degrades to the old
click-to-refocus behavior.

### Known residual path

The rescue covers the window-deactivation path (the common one). If something
inside a *key* window momentarily grabs first responder and disappears without
handing focus back, no key-window transition occurs and the rescue won't fire.
Not observed in practice; revisit if focus ever drops without a window switch.

### Upstream

The root fix belongs in libghostty-spm: `windowDidResignKey` should dim the
cursor (`core.setFocus(false)`) **without** writing the SwiftUI binding, so
focus survives window deactivation. Worth a PR to
`github.com/Lakr233/libghostty-spm`. Once that lands, the app-side rescue's
guard never matches and it becomes dead code that won't fight the fix.

## Verification

Rebuild, start an agent working (so store updates flow), ⌘-Tab away for a few
seconds, ⌘-Tab back. Before the fix this reliably left a hollow cursor; after,
typing lands in the terminal immediately with no click.
