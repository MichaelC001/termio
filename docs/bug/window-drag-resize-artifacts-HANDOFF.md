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

> **Eyes obtained.** The reporter's screenshot (§12) has been decoded down to the
> column: it is an 82-column Claude Code screen rewrapped to 66. §12 also
> measures what the child does with a SIGWINCH, which settles two arguments this
> file was making from assumption, and closes one ordering hole in the daemon.

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

## 12. Eyes on it, finally — and what the screenshot decodes to

2026-09-02. The reporter photographed a drag: *"why 拖动屏幕 tui 乱码"*. The
picture is a wide pane holding a much narrower screen, its box borders broken
into one long run and one short one, and `/rc` split across a row boundary.

**It decodes exactly.** Run `claude` on a real PTY at 82 columns and it draws its
hint row as `⏵⏵ bypass permissions on (shift+tab to cycle)` followed by
`ESC[66G` — `/rc` at column 66. Rewrap that screen to 66 columns and `/` is the
last cell of the row while `rc` wraps; the 78-cell border splits into 66 + 12.
That is the screenshot, glyph for glyph. Reproduced against `termiod-vt`
directly:

```
--- 82 -> 55 (reflow) ---
───────────────────────────────────────────────────────
───────────────────────────
bypass permissions on (shift+tab to cycle) . <- for age
nts / rc
```

So the frame on screen is **a screen drawn for one width, rewrapped to another,
with no repaint over it**. Nothing else produces that shape. Two questions
follow: does the child not repaint, or does its repaint get overwritten?

### 12.1 The child does repaint — measured, not assumed

§3 argued the rewrap is safe for a TUI because "an agent TUI, an editor, a pager
all repaint from their own model". That is true of Claude Code, and now measured
rather than asserted. Captured from a real PTY across a `TIOCSWINSZ`:

```
ESC[?1000h ESC[?1002h ESC[?1003h ESC[?1006h ESC[?25l ESC[2J ESC[H  <redraw>
```

It clears the whole screen and repaints it from home with absolute addressing.
Latency from the ioctl to the first byte, four trials: **0.1–0.3 ms**. zsh's
redisplay, same harness: **7–23 ms**.

Two consequences. The rewrap gate in §3 stands — a program that answers SIGWINCH
this way cannot be broken by a rewrap it immediately paints over. And any frame
of the rewrapped screen that a viewer sees is one *we* put there: the child had
already replaced it.

### 12.2 Closed: the keyframe could describe a screen the child had replaced

`apply_size_policy` resized the PTY, told the sidecar to reflow, and asked for
the snapshot in the same handler — deliberately, and the comment said so: *"these
requests are adjacent to the Resize command in the sidecar FIFO, with no
intervening Write command."* Adjacent to the resize means **before** the child's
answer to it. The keyframe every attachment repaints from was therefore the
rewrapped screen, by construction, and the child's redraw arrived behind it as
ordinary data.

That is a full-screen paint of a screen that is already wrong, shipped on every
resize. Whether a viewer *sees* it is a race it should never have been running:
with Claude Code answering in 0.3 ms the redraw usually reaches the sidecar in
time to be in the capture anyway — an end-to-end recording of a real 82→66 resize
shows a clean keyframe on the pre-fix daemon — but nothing made that true, and a
slower child, or a busier actor, loses it.

Fixed: the resize opens its barrier immediately (so nothing reaches a client
ahead of the grid that describes it) and the **capture waits for the child**.
The child answering its SIGWINCH is the event the capture is actually for, so
the first byte it writes pulls the deadline in to 5 ms — enough to catch a
redraw split across two writes, never enough to be felt. The 40 ms is only the
cap, for a child that never answers; it then gets exactly the old screen, so the
window costs no correctness.

Waiting on a clock instead of on the child is not free, and a test says so.
`E resized` is deferred behind the open barrier, so a fixed settle delays *every*
viewer's notion of the session's size by that much:
`TermiodSizePolicyIntegrationTests.testTheSessionIsTheScreenBeingUsed` fails on a
flat 40 ms settle and passes on the answer-driven one. Any future change here
must keep that test honest rather than widen its tolerance.

Pinned by `session::tests::a_resize_keyframe_carries_the_child_s_redraw`, which
fails without the deferral with the keyframe painting `STALE` — the screen the
child had already replaced — and asserts the deadline moves in when the child
answers.

### 12.3 Fixed: a hold that gave up painted the keyframe anyway

`TerminalKeyframeHold` waits for the surface to reach the keyframe's grid, with
a 250 ms deadline and a 1 MiB flood cap so it stays a hold and not a stall. Both
of those endings **painted the keyframe anyway** — a screen drawn for one grid,
written into a surface laid out at another, which wraps every row somewhere the
daemon never put it. A guaranteed scrambled full-screen frame, followed by the
surface's own reflow of it, followed by the resync that replaced it a round trip
later. A drag is exactly the condition for missing that deadline: the deadline is
main-thread layout, and a drag is a busy main thread.

Both endings now **drop** the keyframe (`TerminalKeyframeHold.abandon`) and arm
the repaint instead. The live bytes queued behind it still go out — they are the
child's, and this is not the layer that may discard them — and the last screen
that was painted correctly stays up until the resync lands. Teardown is the one
ending that still paints, and for the reason it always did: a surface that is
going away has no resync coming, so an imperfectly wrapped final frame beats a
blank one.

`resize-trace … keyframe-held-out` (deadline) and `keyframe-flooded-out` (cap)
name the two in the client log. Pinned by
`TerminalKeyframeHoldTests.testGivingUpDropsTheKeyframeAndKeepsWhatWasQueuedBehindIt`
and `…testAFloodBehindAHeldKeyframeEndsTheWaitWithoutPaintingIt`.

### 12.4 Reported after §12.2/§12.3: inward is clean, outward is not

*"往内拖拽没有问题 往外拖拽还是有问题"*. Two things are worth separating.

**A hole §12.3 opened, now closed.** Dropping the keyframe instead of painting it
leaves the pane on its last correct screen and arms `repaintPending`, and the
arming waited for the surface to report the *exact* grid the session moved to.
Nothing guarantees it ever does: a pane that fills itself is measured in points
by `TerminalGrid.fitting` and floored in pixels by libghostty, and the two can
disagree by a column. The old code hid this — it painted something wrong, and
wrong-but-fresh is invisible next to stale. A backstop now asks for the repaint
500 ms later whatever grid the surface settled at, and a keyframe answering a
repaint *we asked for* is no longer put through the hold (`paintNextKeyframe`):
holding it would wait on the grid that already failed, give up the same way, and
ask again. Pinned by
`TerminalKeyframeHoldTests.testAKeyframeAnsweringARepaintWeAskedForIsNotHeld`.

**The direction itself is asymmetric by construction, and that is unexamined.**
`SharedGridLetterbox` lays the surface out at the *session's* grid for the whole
drag, anchored top-left:

- dragging **inward**, the surface is larger than the pane and clipped — the
  content still reaches every edge of the window, and only the far right and
  bottom are cut, which for a TUI is padding;
- dragging **outward**, the surface is smaller than the pane — the terminal sits
  in the top-left corner of a window that keeps growing around it, for the whole
  drag plus the 150 ms debounce, and then snaps out.

That is what the reporter's screenshot shows: content occupying the left portion
of a wide pane. Whether *that* is the complaint, or whether something is also
wrong with the content itself, is the open question — and it is the same question
§8.1 has been asking for since this file was opened. It needs one screenshot
taken **mid-outward-drag**, before the mouse is released.

If the pin is the complaint, the fix is a real design decision and must be argued
against §4 and §5 rather than tried: §5 removed `viewportPending` precisely so the
surface would stay pinned for the whole drag, and §4 rejected mid-drag barriers
because each shipped a rewrapped screen. §12.2 changes the second half of that
argument — a mid-drag barrier now carries the child's own redraw, not a rewrap —
so the cost §4 measured is no longer the cost. Growing is also the direction that
cannot split a row: a wider surface re-joins, it never re-wraps into a width
nothing was drawn at, which is the objection §5 pinned the surface for. Neither
observation is permission to change it blind.

### 12.5 What is still unproven

Neither fix has been *watched*. The photograph was never reproduced under a
trace: the app was showing only its settings window by the time the daemon fix
was live, and driving a real drag by AppleScript needs the main window up. What
would settle it is one drag with

```sh
log stream --predicate 'subsystem == "sh.termio.app.dev"' --debug --style compact \
  | grep resize-trace
```

running. `keyframe-held-out` in that trace says §12.3 was the frame in the
photograph; its absence says the remaining suspect is elsewhere and this file is
not finished.

One operational trap found while measuring, worth its own line: **the daemon does
not restart when the app is rebuilt.** The dev daemon on the reporter's machine
was running a binary built hours earlier from a worktree that no longer exists,
so every Swift-side rebuild that afternoon was talking to old host code.
`termiod handoff` replaces it in place, keeping the PTYs.

## 13. The other three, and why the fix went out twice

2026-09-04. The reporter, on a build that already carried §12: *"怎么还是有
问题啊？我印象里昨天晚上一个 dev 的版本是可以的"*.

**The build never had §12 in it.** The dev app was built that morning from a
checkout whose `main` sat six commits behind `origin/main`, at the commit
before §12 merged. Grepped against the source it was built from: no
`growingViewportPending`, no `abandon`, no `RESIZE_SNAPSHOT_SETTLE`. Nothing
had regressed; the machine had simply never run the fix. Worth a line in any
future session: **check what the running binary was built from before
believing a symptom.** `termiod status` names the daemon, and the app's own
build time against `git log` names the app.

Meanwhile that same checkout held a day of *uncommitted* work — a separate
investigation, recorded in the memory note `termio-resize-mojibake-family`,
which had found three more causes. Two fix sets existed, neither build had
both, and both touched `TermiodClient.swift` and `session.rs`. They are now
reconciled on one branch.

### 13.1 A hidden pane keeps the grid it left with

The main one. A pane outside the layout still has a live link feeding it
bytes, and its surface keeps whatever grid it had when it stopped being laid
out. Every byte drawn for the session's later widths wraps at that stale one,
and the wrap points are baked into the surface — re-layout cannot undo them,
it only re-wraps the lie at the new width. `repaintPending` never fires,
because it is armed by surface reports a hidden pane does not deliver.

Coming back on screen is now a boundary that takes a snapshot, the way attach
does. It goes *through* the hold, not around it: §12.3's `requestResyncLocked`
force-paints its answer, which is right for a hold that already failed and
wrong for a pane about to be laid out.

### 13.2 The coalescer declared sizes nobody chose

A pane's width also moves when the app animates layout. Those animations pause
long enough mid-flight that the 150ms timer fired on an animation frame: a
traced session open declared 68 columns on its way from 97 to 97. The child's
repaint for that width then races the next resize. 400ms; the real answer is
declaring only at boundaries, which is still not done.

### 13.3 Nothing made the child repaint after the dust settled

Bytes drawn for the old grid can still be in flight when the VT takes the new
one, and only the child can overwrite what they painted. 300ms after the last
resize the foreground gets one more SIGWINCH — re-armed by every resize, so a
drag costs one nudge at the end. A ring replay the daemon knows is unfaithful
gets the same nudge, which is the frozen mangled screen after a handoff: an
idle agent produces no next output, and a viewer already at the session's size
gets no resize either.

cmux solves the same family by pinning the surface's pixels to the authoritative
grid regardless of visibility, checking grid parity both ways, and kicking a
repaint after a grow. The child is our tmux; §13.3 is that kick. A true pin
needs `InMemoryTerminalSession.updateViewport` made public in the fork, which is
the follow-up this file should be reopened for.

