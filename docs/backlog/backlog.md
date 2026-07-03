---
title: Backlog
status: active
type: backlog
created: 2026-07-03
updated: 2026-07-03
related:
  - rfcs/fork-libghostty-spm.md
  - design/session-history-search-resume.md
---

# Backlog
https://x.com/mitchellh/status/2072724957902381319
> Deferred-but-decided work items, each with the trigger that makes it start.
> Not a wish list — an item enters only with a concrete "why" and "when".

## libghostty official packages (watch)

Mitchell Hashimoto announced (2026-07-02) a pure-Swift package family for
libghostty embedders: **GhosttyVT** (raw VT, no rendering), **GhosttyRender**
(Metal renderer, retained-frame + dirty-row tracking), **GhosttyTerminal**
(input over a reader/writer interface, PTY included). As of 2026-07-03 none are
published; the foundation (`include/ghostty/vt/render.h`, nightly signed
`ghostty-vt.xcframework` with macOS + iOS slices) is already public in
`ghostty-org/ghostty`.

- [ ] **Migrate rendering off Lakr233/libghostty-spm** when GhosttyRender /
  GhosttyTerminal ship. Expected wins: the iOS lock-contention class
  (scroll-during-output jank, the 07-03 freeze) disappears by design — render
  state only locks the terminal during `update`; redraw issues addressed by
  dirty-row retained-frame model. The official GhosttyTerminal reader/writer
  interface matches our host-PTY (`PTYProcess`) architecture directly.
  *Trigger: package repos appear (watch @mitchellh, ghostty-org).*
- [ ] **`sessions read` via ghostty-vt formatter API** — the CLI `read` op is
  stubbed ("needs a terminal-core buffer API"). `formatter.h` (plain text / VT
  / HTML export) in the official nightly xcframework is that API. Host-side
  headless VT mirror fed from `PTYProcess`'s byte stream; no rendering-layer
  changes. Keep the C binding thin — GhosttyVT will replace it.
  *Trigger: can start now; vendor a pinned nightly xcframework (tip assets
  rotate per commit).*
- [ ] **iOS local VT mirror for scroll latency** — measure how much composer
  scroll latency is WebSocket round-trip vs renderer lock contention; if the
  wire dominates, run a GhosttyVT instance on-device so scrollback lives
  locally (zero round-trip). *Trigger: after the latency measurement, and
  ideally on GhosttyVT rather than a hand-rolled binding.*

## libghostty-spm soft fork (bridge, not home)

Per `rfcs/fork-libghostty-spm.md` — Option B confirmed, executed as a bridge
until the official packages land.

- [ ] **Fork libghostty-spm and land the deadlock fix** (`receive()` releases
  the session lock before the blocking `ghostty_surface_write_buffer`), plus
  teardown hardening and a real link-delegate hook. Keep the diff minimal;
  PR every patch upstream. *Trigger: now — the freeze mitigation is
  probabilistic and the official replacement has no release date.*
- [ ] **Offer the one-line lock fix upstream first** as a cheap test of
  Lakr233's responsiveness before (or alongside) forking.

## Deferred designs

- [ ] **Session history / search / resume** — direction approved, design
  archived in [session-history-search-resume](../design/session-history-search-resume.md)
  (`status: approved`). *Trigger: after the current `session-share.md` mainline
  ships.*
