---
title: "HANDOFF: window drag still corrupts the terminal mid-drag"
status: draft
type: bug
created: 2026-09-01
updated: 2026-09-02
related:
  - ../design/20260901-pty-size-is-not-the-write-token.md
  - ../design/20260730-termiod-session-protocol.md
  - terminal-resize-no-reflow-HANDOFF.md
  - agent-tui-focus-report-resize-storm.md
---

# HANDOFF — window drag still corrupts the terminal mid-drag

> **§5 fixed, pending eyes.** Sizing was already proven. The mid-drag corruption
> now has a measured cause and a fix with tests that fail without it (§10).
> Nobody has yet *looked* at a drag — Screen Recording is still ungranted — so
> the visual claim is inference from a measured mechanism, not observation.

## 0. Read this first

The reporter's words, in order, across one afternoon on branch
`feat/size-follows-the-device-in-use` (PR #591):

1. "right sidebar 展开折叠 无法 resize tui" — **fixed**, see §2.
2. "resize 过程抖动 and 依然错位" — partly fixed, see §3.
3. "还是会抖动" — partly fixed, see §4.
4. "drag 过程中还是会乱？结束的时候不乱" — **fixed**, see §5 and §10.
5. "完全不会 resize 了" — a regression introduced chasing #4; fixed, see §6.

Nine commits, then a tenth that replaced the fifth attempt at §5. The visual
half was changed five times by agents that **cannot see the screen** —
`screencapture` is still refused (no Screen Recording), though Accessibility is
now granted — so no claim in this file comes from watching a drag. §5 is now
argued from the daemon's own ordering and pinned by tests that fail without the
fix, which is the strongest evidence available without a camera. Getting eyes on
it is still the first thing a follow-up should do.

## 1. How to get evidence (do this before changing anything)

The client logs a four-line trace at debug level. Nothing else in this
investigation produced a usable signal.

```sh
log stream --predicate 'subsystem == "sh.termio.app.dev"' --debug --style compact \
  | grep resize-trace
```

```
resize-trace <session> declare 45x97 rendering=true   # what this pane told the daemon
resize-trace <session> session-is 45x97               # what the daemon answered
resize-trace <session> surface-at 45x97               # what libghostty laid the surface out at
resize-trace <session> resync-requested               # the pane asking for a paintable keyframe
resize-trace <session> keyframe-held-out              # a held keyframe gave up on its surface
```

Since §5, the healthy trace for a resize is `declare` → `session-is` →
`surface-at` → nothing. `resync-requested` after a resize means the hold was
abandoned; `keyframe-held-out` says the 250ms deadline is why.

Four links log into one stream — one per open session, plus the companion
bridge. Before the session name was added, their interleaved bursts read as a
loop and cost an hour. Two other measurements that settle arguments quickly:

```sh
# what the daemon believes
env -u TERMIOD_SOCK TERMIO_CHANNEL=dev termiod list --json

# what the kernel actually holds — the child reflows from this, not from us
python3 -c 'import os,fcntl,termios,struct
fd=os.open("/dev/ttys004", os.O_RDONLY|os.O_NOCTTY|os.O_NONBLOCK)
print(struct.unpack("HHHH", fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0"*8))[:2])'
```

**`TERMIOD_SOCK` leaks.** Any shell inside Termio carries it, it overrides
`TERMIO_CHANNEL`, and `open` passes it to the app — so a dev build launched from
a Termio terminal attaches to the **release** daemon and shares the user's real
sessions. Two apps on one session is also a faithful reproduction of the original
bug, so this trap both causes and hides it. Launch with
`env -u TERMIOD_SOCK … open ./termio-dev.app`.

## 2. Fixed and proven: the session sized to the smallest viewer

`#580`/`#586` shipped `size = min(viewport of attachments rendering)`. Any second
viewer — another window on the same daemon, a phone with the session open — held
every other one at its width, so collapsing a pane's sidebar moved nothing.

Measured before the fix: one window, ⌘⌥0 moves the PTY 41×63 ↔ 41×97 every time;
a second window at 700×600 on the same session pins it at 41×61 and four toggles
move nothing, the app logging `PTY is now 41x61; this pane has room for 41x70`.

Now: `size = viewport of the most recently *used* attachment`, where a use is
typing, declaring a changed viewport, or attaching — never output, never a device
report, never a token claim. tmux's `latest` with zellij's rendering filter. See
§11 of the size-policy RFC. Covered by `session.rs` unit tests and
`TermiodSizePolicyIntegrationTests` against a real daemon.

## 3. Fixed: the screen was truncated instead of rewrapped

termiod's VT resizes without reflow on purpose — a shell's SIGWINCH redisplay
moves the cursor up by a row count computed from the *old* width, so rewrapping
under it duplicates the prompt (the ⌘D report). Every attachment then repaints
from that screen, so a line the program had wrapped stayed broken where it was
broken: widen the window and rows start mid-word. `mage in clipboard` in the
reporter's screenshot is `image in clipboard` with the `i` still on the row above.

Now gated on what is on screen: a shell gets the truncating resize, anything else
gets the rewrap. **The first version of this gate was wrong and shipped**: it
asked `foreground.job`, but an agent session is `zsh -ilc exec claude`, where
`exec` replaces the shell image — the child *is* the agent, its pgid is the
session's own, and the answer was always "no job". Every agent session kept the
truncating resize. It now matches argv0 against a closed set of shell names.

Both directions are pinned in `vt/tests/resize_reflow.rs`
(`widening_does_not_re_join_a_wrapped_line`,
`widening_with_reflow_re_joins_a_wrapped_line`) and the classifier in
`only_a_shell_gets_the_truncating_resize`.

## 4. Fixed: a barrier per intermediate size

A viewport flushed on a fixed cadence made a drag ~20 barriers a second — each
one quiesces the session, resizes, and pushes a fresh keyframe to every
attachment, racing the child's own redraw. Ghostty affords 25ms because its
resize is an ioctl on a PTY one surface owns; ours is a barrier. tmux
rate-limits a pane to one resize per 250ms, zellij collapses a burst to its last,
cmux debounces 180ms.

Now one send per drag, at the end, 150ms after the pane stops moving. Measured on
a real 2.8s drag: six declarations, each answered by the daemon in 2–11ms.

## 5. **Fixed: the screen was wrong *during* the drag**

Reporter: *"drag 过程中还是会乱？结束的时候不乱"* — the end state is correct, the
journey is not.

The two behaviours this file oscillated between were both wrong, and the reason
is one fact nobody had checked in the daemon:

`apply_size_policy` calls `begin_snapshot_barrier()` **before**
`emit_event(Event::Resized)`, and `emit_event` defers events behind an open
barrier (`queue_non_data`). So on the wire the order is always

```
S (at the new grid) → E ready → buffered data → E resized (the new grid)
```

The client learns the new size *after* the keyframe describing it. **No
client-side ordering can win that**, which is why "let the surface lead its own
declaration" did not: the pane cannot know the grid before the frame that
carries it, and even if it guessed, the daemon answers in 2–11ms while a SwiftUI
layout pass costs a main-thread hop.

So the keyframe was painted onto a surface still laid out at the old grid — one
mangled full-screen frame — and the repair was a second keyframe asked for after
the layout pass. Two full repaints per resize, and a slow drag crosses several
cell boundaries (measured: six declarations in 2.8s). That is the mess.

The fix is to stop predicting and start waiting. `TerminalKeyframeHold`
(`Sources/termio/Terminal/Termiod/TermiodClient.swift`) holds a keyframe whose
grid the surface is not laid out at, queues the bytes that arrive behind it, and
emits both — in order — the moment libghostty reports that grid. One paint per
resize, and it is the right one. A 250ms deadline and a 1MiB cap keep it a hold
rather than a stall; either ending falls back to the old resync.

With the hold in place the surface can stay pinned to the session's grid for the
*whole* drag, so `viewportPending` and its 600ms window are gone. That was the
half that made a long drag worse: after the first mid-drag flush the surface
followed the pane for 600ms at a time, re-wrapping the old screen at widths
nothing had been drawn at.

Ghostty has neither problem because it has neither half of the architecture: one
VT, no host, no keyframe, and the PTY resizes continuously so the child's output
is always fresh for the current width.

## 6. Regression, fixed: pinning against a host with no size policy

Chasing §5, the letterbox was regated from `!isWriter` to "the session's grid
differs from this pane's". Correct under a size policy; catastrophic without one.
An older daemon — the reporter's VPS, `route=ssh:ukvps`, `caps=events,snapshot`
— reads a resize as *set the PTY size, from the writer*, so the pane's own grid
**is** the session's. A difference there is a declaration that host will never
answer, and the surface stayed pinned to it forever: *"完全不会 resize 了"*.

The pane now asks the handshake (`viewport` capability) before it letterboxes at
all. Any future gate on this path must ask the same question.

## 7. The architectural answer, not yet attempted

cmux does not have this bug family because it never runs two terminal
authorities in one session:

- a local pane is `ioMode: .exec` — ghostty owns the child, the PTY and the
  terminal protocol (`TerminalSurfaceIOMode.swift:7`);
- a remote pane is `.manualMirror` — *"the embedder owns the PTY and terminal
  protocol while Ghostty mirrors output for rendering and encodes only user
  input"* (`:12`), with remote tmux as the single authority for the screen;
- a phone watching a Mac pane does not change the grid at all — it **shrinks the
  font** (`MobileViewportFitGeometry.swift:103`).

termio's `.inMemory` is cmux's `manual`, not `manualMirror`: libghostty is a full
terminal on the client, reflowing on its own authority, while termiod runs a
second authoritative VT. Every artifact in this file lives in the gap between
them. `GHOSTTY_SURFACE_IO_MANUAL_MIRROR` is **not upstream** — upstream
`include/ghostty.h` has no io mode at all; cmux added it to their fork, and we
maintain `termio-sh/libghostty-swift` as ours.

A mirror mode there would delete this class by construction. It is the same shape
of change as `.exec` → `.inMemory` was, so it wants an RFC before code — and it
must be argued against §A's anti-100× invariant, since a mirror still must not
put a per-frame grid encoder between the PTY and the pipe.

## 8. What to investigate next

1. **Get eyes on it.** Screen Recording for whoever drives this, or a screen
   recording from the reporter. Accessibility is now granted; Screen Recording is
   not, and `screencapture` still answers *could not create image from display*.
   §5 is fixed at the mechanism, and the mechanism is measured, but nobody has
   watched a drag.
2. ~~Decide §5 deliberately~~ — decided, see §5. Neither pinned nor leading was
   right on its own; the keyframe had to wait.
3. ~~Why does `resync-requested` fire after every resize?~~ — answered in §9 and
   removed by §5's fix, which makes the barrier's own keyframe the repaint.
4. ~~**The 45↔46 row oscillation at launch**~~ — **fixed, and the guess here was
   wrong.** `TerminalGrid.fitting` is not off by one and points-vs-pixels had
   nothing to do with it. The trace was extended to carry the inputs behind each
   declaration (`resize-trace … measure pane=… cell=… scale=… grid=…`), and they
   name the cause outright:

   ```
   36.178 WINDOW at-content-installed  layout=640x468
   36.219 measure pane=465x890  cell=9.5x19  scale=2  grid=46x47
   36.344 WINDOW after-frame-restore   layout=1150x890
   36.378 declare 46x47  →  session-is 46x47      ← PTY resized, barrier, keyframe
   36.419 WINDOW after-toolbar         layout=1150x870   ← the toolbar costs 20pt
   36.444 measure pane=465x870  cell=9.5x19  scale=2  grid=45x47
   36.594 declare 45x47  →  session-is 45x47      ← all of it again
   ```

   `fitting` is right both times: `floor((890−4)/19) = 46`, `floor((870−4)/19) =
   45`. The pane really was 890pt tall and then really was 870. `installToolbar()`
   ran *after* `makeKeyAndOrderFront`, so every launch measured a content rect one
   row too tall, declared it, and had the daemon answer — resizing the PTY,
   opening a barrier and pushing a keyframe for a grid that lived 40ms.

   Fixed by installing the toolbar right after the content view controller and
   before the window is shown, so the content height is final before anything
   measures it. Measured after: `layout` is 870 from the first pass, and the
   launch sends **zero** redundant declarations where it used to send two.
5. **Redeploy the VPS daemon** (`termiod deploy --host ukvps`); remote sessions
   are on an old build and will keep behaving like the pre-policy world. They
   also predate §10, so a resync there is still dropped.
6. **Consider the mirror RFC** (§7) before adding any further reconciliation
   logic to the client. The pile is smaller than it was — the lead is gone and
   the resync is now a fallback rather than the mechanism — but §7 still deletes
   the class by construction.

## 9. Independent probe (codex), and what its drag left in the trace

A second agent re-ran the investigation from this document. Its result: a focused
3s edge drag ended with the daemon and `TIOCGWINSZ` **both at 45×21** — the two
agree, so the sizing chain is consistent end to end and §2 holds. It could not
get Screen Recording either, and had no retained trace, so it adds nothing to §5.

Two agents are now blind on the same half of the same bug. **The blocker is a
permission, not a question about the code**, and it should be cleared before
anyone writes another line: Screen Recording + Accessibility for the session
driving the app, or a five-second screen recording of a drag from the reporter.

The trace *was* still capturing during that probe, and it settles one open
question and opens another.

**§8.3 answered: `resync-requested` still fires after every resize.** Even with
the surface leading its own declaration:

```
20:05:32.561 6E769100 declare 45x21 rendering=true
20:05:32.561 6E769100 session-is 45x21
20:05:32.562 6E769100 surface-at 45x21
20:05:32.562 6E769100 resync-requested
```

The surface reaches the grid one millisecond *after* the daemon's answer, so the
keyframe that rides behind `E resized` still lands on a surface that has not been
re-laid-out. The ordering fix moved the race, it did not remove it. A client
cannot win this by predicting: the fix is to hold the post-barrier keyframe until
`surfaceGrid == authoritativeGrid` (with a timeout) rather than paint it and ask
again — or to stop having two VTs at all (§7).

**New: two sessions declare identical viewports at the same instant.**

```
20:05:32.561 D65810C6 declare 45x21 rendering=true
20:05:32.561 6E769100 declare 45x21 rendering=true
20:05:32.561 5AAA195E declare 45x44 rendering=false
```

`D65810C6` and `6E769100` are different sessions reporting the *same* grid in the
same millisecond, both `rendering=true`, and both resize. A split would give them
different geometry — a side-by-side split halves the columns, a stacked one
halves the rows — so identical numbers mean two panes each measuring the whole
pane rect. `SharedGridLetterbox` computes `paneGrid` from
`paneFrames[id] ?? bounds`, and a session with no split geometry falls back to
`bounds`: the entire pane. Hidden panes are meant to be excluded by
`rendering=false` (`5AAA195E` correctly is), so the question is why two are
marked visible at once. Worth checking `store.visiblePaneIDs` before assuming the
letterbox is at fault.

## 10. Found while measuring §5: a resync was never answered

`SessionMsg::ResendSnapshot` asked the sidecar for a capture but never opened the
attachment's snapshot barrier. `finish_snapshot` matches every capture against
the request the attachment is waiting on (`plane.pending_request()`), and with no
barrier open that is `None`, so **every client-requested resync was captured and
then discarded as stale**. The client asked for a repaint, the daemon produced
one, and nobody ever saw it.

Measured, not read: with the hold disabled, an integration test against a real
daemon saw `resync-requested` go out and no second keyframe come back. With the
one-line barrier restored, the same test sees two keyframes per resize — the old
design's true cost — and with the hold enabled, one.

This is the fallback §5 degrades to, and the phone bridge's only recovery from
bytes it dropped downstream (`TermiodSessionLink.requestResync`). It has been
broken on `main` for as long as the verb has existed. Fixed in
`termiod/src/session.rs`; pinned by `a_resync_a_client_asked_for_reaches_it`.

## 11. What is pinned, and what a follow-up must not undo

- `TerminalKeyframeHoldTests` — the ordering rule as pure state: a keyframe at
  the surface's grid passes through, one ahead of it waits, live bytes queue
  behind it in order, a newer keyframe supersedes what was queued, and the flood
  cap and deadline both end the wait exactly once.
- `TermiodSizePolicyIntegrationTests.testAResizeKeyframeWaitsForTheSurfaceAndPaintsOnce`
  — the same rule end to end against a real daemon, including that a resize costs
  exactly one repaint. It fails without the hold (`("1") is not equal to ("0")`).
- `session::tests::a_resync_a_client_asked_for_reaches_it` — §10.
- §3's `vt/tests/resize_reflow.rs` and §2's size-policy integration tests are
  untouched and still pass.
