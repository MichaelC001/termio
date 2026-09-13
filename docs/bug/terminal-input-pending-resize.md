---
title: Input during a pending host resize
status: archived
type: bug
created: 2026-09-13
updated: 2026-09-13
---

# Input during a pending host resize

> Historical investigation for [issue #633](https://github.com/termio-sh/termio/issues/633).
> The affected Swift PTY implementation was removed before this patch reached
> `main`. The reported visual symptom remains unverified on the current backend.

Reported September 13, 2026: Claude input and its cursor sometimes appear above
the prompt line after switching away and back. The exact visual symptom has
not yet been reproduced locally; the report does not establish whether the
switch was between apps or between termio sessions.

Investigation found a concrete timing defect: `resizeFromHost` records the
surface's new grid immediately but coalesces the PTY update for 50 ms.
`claimHostOwnership`, called before surface input is written, previously
returned early when the host already owned the size. That allowed input to
reach the child while its kernel terminal size still described the old grid.

The patch at `d9ac2430` cancels the deferred work and applies the latest host grid
before returning, regardless of previous ownership. Unchanged sizes remain
no-ops. Background host layout changes still respect companion ownership.
This closes that input timing gap; it does not establish that all Claude
cursor-placement glitches are fixed or force a child to finish repainting
before it handles input.

## Historical verification

At `d9ac2430`, `tools/tests/pty-host-resize.swift` launches a real PTY child and asks `stty
size` for its kernel grid before the main runloop can deliver the coalesced
resize. Before the fix it reports `24 80` instead of `40 120`; after the fix it
reports `40 120`. The same test checks companion ownership during a background
host resize and restoration of the host grid on host input.

The test and fix remain available at that commit. The test was removed from the
merged tree because it depends on the deleted `PTYProcess` class.

## Resolution against main

`main` at `cebe4716` owns PTYs in `termiod/src/pty.rs`.
`Sources/termio/Terminal/Termiod/TermiodClient.swift` queues input on its work
queue and declares viewports separately. For hosts that support size policy,
`applyWriter` deliberately does not reassert the writer's grid. The daemon
chooses a shared grid from rendering attachments; an input-side host-size
claim from the old implementation has no direct equivalent here.

The merge keeps that implementation and removes the obsolete Swift class and
its standalone test. There is no production-code change relative to `main`.
This records a superseded patch, not a verified fix for the screenshot on the
current backend.

Still needed: reproduce repeated app/session switches with Claude while it
streams output and while editing a multiline prompt, with and without window
or pane resizing. Confirm both the input text and cursor remain in the prompt.
