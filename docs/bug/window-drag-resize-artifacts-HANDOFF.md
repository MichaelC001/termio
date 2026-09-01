---
title: "HANDOFF: window drag still corrupts the terminal mid-drag"
status: draft
type: bug
created: 2026-09-01
updated: 2026-09-01
related:
  - ../design/20260901-pty-size-is-not-the-write-token.md
  - ../design/20260730-termiod-session-protocol.md
  - terminal-resize-no-reflow-HANDOFF.md
  - agent-tui-focus-report-resize-storm.md
---

# HANDOFF — window drag still corrupts the terminal mid-drag

> **OPEN.** Sizing is fixed and proven. What is still wrong is what the screen
> *looks like* while a window is being dragged. Everything below is measured, not
> reasoned; the open questions at the end are the ones nobody has data for.

## 0. Read this first

The reporter's words, in order, across one afternoon on branch
`feat/size-follows-the-device-in-use` (PR #591):

1. "right sidebar 展开折叠 无法 resize tui" — **fixed**, see §2.
2. "resize 过程抖动 and 依然错位" — partly fixed, see §3.
3. "还是会抖动" — partly fixed, see §4.
4. "drag 过程中还是会乱？结束的时候不乱" — **the live one**, see §5.
5. "完全不会 resize 了" — a regression introduced chasing #4; fixed, see §6.

Nine commits. The sizing half is tested and I stand behind it. The visual half
(§5) has been changed five times by an agent that **cannot see the screen** —
`screencapture` is refused (no Screen Recording) and `osascript` returns -25211
(no Accessibility) for this session, so every visual claim in this file comes
from the reporter's screenshots or from the trace in §1, never from observation.
That is the single biggest reason this took so long, and the first thing a
follow-up should fix.

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
```

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

## 5. **Still open: the screen is wrong *during* the drag**

Reporter, after the fixes above: *"drag 过程中还是会乱？结束的时候不乱"* — the end
state is correct, the journey is not.

There are only two coherent behaviours and termio has been oscillating between
them because each was tried without being able to see the result:

| | during the drag | why it is wrong |
| --- | --- | --- |
| **surface follows the pane** | libghostty re-wraps the *old* screen once per frame, at widths nothing was ever drawn for | the mess the reporter sees |
| **surface pinned to the session's grid** | nothing moves, padding grows | correct-looking, but the keyframe after the resize lands on a surface still at the old grid, paints mangled, and needs a second repaint (`resync-requested` fires after every resize in the trace) |

The current commit tries to take both: pinned while the pane is moving, leading
from the moment the declaration is written to the wire, so the keyframe lands on
a correctly-sized surface. **Unverified by anyone who can see it.**

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

1. **Get eyes on it.** Screen Recording + Accessibility for whoever drives this,
   or a screen recording from the reporter. Five blind changes is four too many.
2. **Decide §5 deliberately**, with the trace open: does the pinned or the
   leading surface look better mid-drag? They are one boolean apart today
   (`viewportPending`), so the experiment is cheap.
3. **Why does `resync-requested` fire after every resize?** If the ordering fix
   in §5 is right it should now be rare. If it still fires every time, the
   keyframe is still landing on a mis-sized surface and the extra repaint is a
   second visible paint per resize.
4. **The 45↔46 row oscillation at launch** in the trace: the pane declares 46,
   then 45, and the surface alternates. Suspect the half-cell slack in
   `letterboxSize` against libghostty's own padding rounding — one of the two is
   off by a row.
5. **Redeploy the VPS daemon** (`termiod deploy --host ukvps`); remote sessions
   are on an old build and will keep behaving like the pre-policy world.
6. **Consider the mirror RFC** (§7) before adding any further reconciliation
   logic to the client. Each patch so far has been correct in isolation and the
   pile is now the problem.
