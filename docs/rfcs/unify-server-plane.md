---
title: Unify the server plane in Rust, reduce the Mac app to a viewer
status: draft
type: rfc
created: 2026-08-19
updated: 2026-08-19
related:
  - one-path-local-through-termiod.md
  - one-path-local-through-termiod.review-claude.md
  - one-workspace-source.md
  - one-workspace-source.review-codex.md
  - remote-git-plane.md
  - 20260805-termiod-device-architecture.md
  - 20260818-termiod-web-client-ghostty-wasm.md
---

# Unify the server plane in Rust, reduce the Mac app to a viewer

> One server — `termiod` — owns every answer two people on two machines would
> expect to match. Swift renders and nothing else. This is the execution plan
> across the four RFCs that already argued the pieces, corrected against the
> tree as it stands on `main` at `7fedc72`.

---

## 0. What this document is, and is not

It is **not** a re-argument. `one-path-local-through-termiod.md` made the case
and inventoried the split; `one-workspace-source.md` and its codex review
settled the workspace reference; `remote-git-plane.md` staged git. This document
does three things those four cannot do individually:

1. **Accounts for what is already built**, including on unmerged branches, so
   the next person does not rebuild it (§1).
2. **Draws the boundary as a file-by-file table** — stays Swift, moves to Rust,
   deleted — with real line counts measured today (§2).
3. **Orders the stages against the blocker**, and fixes the citations the source
   RFCs have drifted on (§3, §4).

Where it disagrees with an existing RFC it says so and shows the code (§5).

The deciding rule is unchanged, from device architecture §4.1: *would two people
watching this session from two different machines expect the same answer?* Yes →
Rust. No → Swift.

---

## 1. What is already done

Measured on 2026-08-19. Branch diffs are `git diff --stat main...<branch>` from
the main checkout; `main` is `7fedc72`.

### 1.1 Landed on `main`

Five things the source RFCs list as missing or as future stages are **already on
`main`**, and three of them carry stale citations that would send an
implementer down a dead path.

| Item | Where | Which RFC still calls it open |
| --- | --- | --- |
| **The `(device, root)` workspace reference exists.** `Checkout` — `device: KnownDevice`, `root: String?`, plus `localRoot`, `isOnAnotherDevice`, `deviceIdentity`, and identity-based `==`/`hash` keyed on `host_id` before alias | `Sources/termio/TermioStore/DeviceContext.swift:56-101`, built by `TermioStore.checkout(for:in:localRoot:routeDeviceID:)` at `TermioStore.swift:513-526` | `one-workspace-source.md` §2 proposes `ProjectLocation`; `remote-git-plane.md` §8.1 says the decision "is unresolved … **This RFC is blocked on that decision**". Both are stale — `grep -rn ProjectLocation Sources/ Shared/` → **0**, and `Checkout` is the shipped answer under a different name |
| **The panes stopped asking a session how it was opened.** `grep -rn 'sshHost' Sources/termio/FileBrowser/` → **0** | commit `58dc85e`, on `main` | `one-workspace-source.md` §5 marks Stage 0 "implemented" but attributes it to a branch and names a test class (`InspectorWorkspaceTests`) that does not exist. The real suite is `Tests/termioTests/InspectorCheckoutTests.swift`, 6 tests |
| **SSH ControlMaster multiplexing on the app's own `ssh`.** `multiplexingArguments(host:)` probes `ssh -G`, refuses to override a user's `ControlMaster no`, caps `ControlPath` at 100 bytes, and is applied in `Transport.ssh` | `TermiodClient.swift:208-236`, applied at `:381` | `one-path-local-through-termiod.md` Stage 2 item `4a` asks for exactly this. It is done. Only `BatchMode`/`ConnectTimeout` are absent |
| **`daemonBinaryPath()` no longer resolves a cwd-relative dev path.** Order is `TERMIO_TERMIOD_BIN` → `Bundle.main` resource → checkout walk anchored at the *binary*, not `currentDirectoryPath` | `TermiodClient.swift:94-146` | `one-path-local-through-termiod.md` §5.2 item 1 and `one-binary-and-a-daemon-that-ships.md` §1 both lead with the cwd bug. Fixed. What remains true is that **nothing copies the binary into the bundle** — `grep -n termiod scripts/build-app.sh .github/workflows/release.yml` → 0 |
| **Tombstones are decoded and cleared client-side.** | `TermioStore+Termiod.swift`, `DeviceSessions.tombstones` at `DeviceContext.swift:113-120` | closed by PR #324, correctly recorded in the one-path RFC's own revision |

### 1.2 `feat/termiod-wss` — 5 commits, 69 files, +18,791/−4

The largest body of unmerged work, and it is **not** the CompanionServer
migration. It is a third client and a transport, and it adds **zero protocol
verbs**.

| Commit | What it adds |
| --- | --- |
| `2010fa4` | WSS handshake gating — `termiod/src/wss.rs` (1,075 lines, new): loopback-only bind, Origin allowlist, 24-byte `/dev/urandom` token presented as the `termiod.token.<t>` subprotocol, `termiod pair` to mint/rotate, rotation watched with `notify` and closing live splices with `CloseCode::Policy` |
| `abcda40` | `docs/design/20260818-termiod-web-client-ghostty-wasm.md`, 1,039 lines |
| `0ff80f0` | The session protocol over a WebSocket. `splice()` opens a fresh `UnixStream` to `paths::socket_path()` and copies bytes verbatim in 64 KiB chunks; WebSocket message boundaries are deliberately not frame boundaries. `termiod/tests/wss_bridge.rs`, 803 lines, 10 tests |
| `8ca91ae` | `scripts/check-ghostty-pin.sh` + `.github/workflows/ghostty-pin.yml` — holds libghostty-swift, libghostty-rs and the browser's wasm to one ghostty sha |
| `418dfec` | `web/client/` — 51 files, React 19 + Vite, an unforked prebuilt `ghostty-vt.wasm` pinned by sha256, canvas2d renderer, 219 vitest cases |

Three facts that matter for planning:

- **`termiod/src/protocol.rs` is untouched.** `git diff --name-only
  main...feat/termiod-wss -- termiod/src/protocol.rs` is empty. The browser is a
  *subset* re-implementation in TypeScript, advertising
  `["events","snapshot","scrollback"]` and no `files`/`git`/`upload`.
- **No Swift is touched.** `git diff --name-only main...feat/termiod-wss | grep
  -E '^(Sources|Shared|Tests)/'` → nothing. It does not move CompanionServer and
  does not intend to; the design doc's non-goals name "Replacing the Mac or iOS
  apps," and the default attach mode is `observe` so a browser cannot steal the
  write token.
- **Merge risk is near zero.** `git log --oneline main --not feat/termiod-wss --
  termiod/` is empty: `main` has not moved under `termiod/` since the branch
  point `615f49c`. `termiod/ARCHITECTURE.md` is byte-identical on both.

Two gaps the branch carries: nothing in CI runs `vitest`/`tsc`/`vite build` for
`web/client/`, and `termiod/ARCHITECTURE.md` still describes termiod as
Unix-socket + `termiod stdio` only.

**Accounting:** this branch is worth merging on its own terms — it proves the
protocol is transport-agnostic (invariant #4) with a byte-identical splice, and
it is 100% additive. It is **not** progress on the Swift→Rust boundary, and this
plan does not depend on it.

### 1.3 `feat/one-workspace-source` — 1 commit, 1 file, +5/−1

`7fc1481 style(sidebar): match the device name to the toolbar glyph color`,
touching `Sources/termio/Sidebar/DeviceSwitcher.swift` only. **The Stage 0 work
is on `main`, not on this branch.** The branch is a cosmetic leftover; nothing
of the ProjectLocation model exists in code anywhere.

### 1.4 `wip/one-binary-rfc` — 1 commit, 2 docs, +884

`docs/rfcs/one-binary-and-a-daemon-that-ships.md` (214 lines) proposed shipping
`termiod` inside the `.app` **and** merging the two binaries — `termiod` becomes
a mode of `termio`. The review (670 lines) refused it on six blockers. The two
that must not be re-proposed:

- **B1** — a daemon named `termio` copied to Application Support lands at
  `…/Application Support/termio[-dev]/bin/termio`, byte-for-byte the path
  `CommandLineTool.supportCopyURL` owns (`SessionControl.swift:798,803,829`) and
  every installed hook command names absolutely. The hook ends `2>/dev/null ||
  true` (`HookListener.swift:307`), so status reporting would die silently.
- **B2** — the rename's headline reason is not real. Hooks invoke an absolute
  path plus five flags and a dialect-dependent stdout contract
  (`HookListener.swift:289,303-315`), not a binary name. And one-path §7.5 makes
  `scripts/termio` a *router* to `termiod`: a router named `termio` cannot
  dispatch to a binary named `termio`.

Salvaged and folded into this plan: ship the daemon in the bundle (§4 Stage 4),
the launchd-job repair, and the observation that version negotiation is mostly
already built (`daemon.rs:480-486`).

### 1.5 Empty relative to `main`

`refactor/workspace-device`, `refactor/workspace-stage2`, `docs/workspace-model`,
`feat/remote-project-picker` — all four produce no output from `git log
--oneline main..<branch>` and an empty `git diff --stat main...<branch>`.
Confirmed; they can be deleted.

### 1.6 The daemon's side of the workspace plane, verified

Not a branch — shipped in `termiod/` on `main`, and unreached from Swift.

| Verb | Handler | Stateful? |
| --- | --- | --- |
| `fs.list` | `daemon.rs:1021-1056` → `files::list` (`files.rs:71`) | **No.** Canonicalises the root, confines each path (rejects `..` and symlink escape, `files.rs:49-68`), pages at 2,000 entries, stubs `.git`/`.hg`/`.svn` as `unloaded_dir`, and fails one path in a batch alone |
| `fs.read` | `daemon.rs:1058-1109` → `files::read` (`files.rs:181`) | **No.** Absolute path, 1 MiB soft cap, replies `fs_file` then `F` chunks |
| `fs.match` | `daemon.rs:1110-…` | **Yes** — needs a `subscribe_resource` to have built the name index; without one it honestly answers `coverage: 0.0` |
| `fs.search` | streams `search_results` events, then `fs_searched`; cancellable | **No**, but streaming |
| `git:` resource, `git.diff` | `resource.rs`, `git.rs` (501 lines: `run_status` + `run_diff` and nothing else) | resource **yes**, `git.diff` no |

Swift reaches none of them: `grep -rn '"fs\.' Sources/ Shared/` → **0**;
`grep -rn '"git\.' Sources/ Shared/` → **0**.

---

## 2. The boundary

### 2.1 Stays Swift — the viewer, and the stopping line

These fail the two-observers test outright, or are macOS-coupled. Nothing in
this plan touches them, and a future stage that proposes to must argue against
this list rather than around it.

| Area | Lines | Why it stays |
| --- | --- | --- |
| libghostty surface, `TerminalPane`, `SplitTree`, every `*View` | `Sources/termio/Terminal/` 6,218 · `Sidebar/` 1,971 · `Info/` 5,813 | Rendering, layout and panes are client concerns — invariant #5 |
| `OSCProgressScanner` (`Sources/termio/Agents/`) | — | A byte-stream scan. Every client receives the same bytes; a host opinion of "working" on the wire is the host deciding presentation |
| `AgentStatusRules` — screen-rule agent status | `TermioStore+TerminalSurface.swift:356-366` | Reads the *rendered viewport*, which every client already holds |
| Theme, palette, fonts, keybindings | `Theme/` 527 · `Keybindings/` 628 | The `grid_diff` refusal (`TermiodClient.swift:27`) is the same rule: the host must never resolve a colour |
| `TaskNotifications`, `MenuBarController`, keychain reads, `NSWorkspace`, Quick Look | across `App/` 4,320 · `Companion/Usage/` | This Mac's Notification Center is this Mac's |
| Encoding a human keypress | `Terminal/Ghostty/` | Needs an `NSEvent` and ghostty's key encoder. Rust must not grow a model of one — invariant #5 wearing a keyboard |
| Session grouping, naming, `termio://session/<uuid>` links | `TermioStore/` | The project tree is the user's arrangement, not the device's |
| `focus`, `notify` CLI verbs | `TermioStore+SessionControl.swift:44-53` | Name *this* window and *this* Mac |

### 2.2 Moves to Rust

Ordered by how ready the daemon already is.

| Responsibility | Swift today | Daemon state | Stage |
| --- | --- | --- | --- |
| Directory listing, file read | `SSHFileSystemProvider.swift` 531 + `SFTPClient.swift` 878 (SFTP over `ssh -s host sftp`); local `FileManager` | **Shipped**, stateless | **1** |
| Content search | `ContentSearch.swift` 144 (`git grep` via `Process`) | **Shipped**, streamed + cancellable | 2 |
| Filename fuzzy finder | local walk | **Shipped**, needs a subscription for coverage | 3 (blocked) |
| Filesystem change notification | `FileTreeWatcher.swift` 139 (FSEvents), no remote equivalent | **Shipped** as the `fs:` resource | 3 (blocked) |
| Git status | `GitService.swift:958-984` → `/usr/bin/git` | **Shipped** as the `git:` resource | 3 (blocked) |
| Git diff for one path | `GitService.diffText` | **Shipped** (`git.diff`) | 2 |
| Git history, commit contents, branch compare, discard, `.gitignore`, remote/PR URLs, clone info, stall fingerprint | `GitService.swift` 985 total, 12 verbs | **Absent** — `git.rs` is `run_status` + `run_diff` | 6, per `remote-git-plane.md` §5 |
| Worktree enumeration | `WorktreeService.swift` | **Absent** | 6 |
| Foreground job / argv / cwd | `PTYProcess.swift:807,868,925` | **Absent** — no `tcgetpgrp` in `termiod/src` | 5 |
| Session roster, `read`, `send`, `watch`, `spawn`, `close` | `TermioStore+SessionControl.swift` 1,040 | Verbs exist; the CLI talks to the Swift socket | 7 |
| Agent hook sink | `HookListener.swift` 944, `agent-status.sock` on this Mac | `set_status` exists; nothing routes a hook into it | 7 |
| PTY ownership | `PTYProcess.swift` 996 | **Shipped** (`pty.rs`) | 8 |

### 2.3 Deleted outright

| File | Lines | When | Gate |
| --- | --- | --- | --- |
| `Sources/termio/FileBrowser/SFTPClient.swift` | 878 | Stage 1 | `grep -rn 'SFTP' Sources/ \| wc -l` → 0 |
| `Sources/termio/FileBrowser/SSHFileSystemProvider.swift` | 531 | Stage 1 | same |
| `Tests/termioTests/SSHFileSystemProviderTests.swift` | 508 | Stage 1 | same |
| `Checkout.sftpAlias` + its branch in `FileBrowserView.swift:77-80` | ~12 | Stage 1 | same |
| `Termiod.isEnabled` and every branch on it | `TermiodClient.swift:46` | Stage 8 | `grep -rn 'TERMIO_TERMIOD\b' Sources/ \| wc -l` → 0 |
| `PTYProcess(` construction | `TermioStore+TerminalSurface.swift:228-231` | Stage 8 | `grep -rn 'PTYProcess(' Sources/ \| wc -l` → 0 |

**`RemoteFileTree.swift` (507 lines) is NOT deleted, and that is a deliberate
change from the brief.** It is three things: `RemotePreviewStorage`/`Lease` (the
0700 `mkdtemp` staging for read-only previews, referenced from
`App.swift:497` and `TermioStore.swift:246,1609`), `RemoteFileNode` +
`RemoteFileBrowserModel` (the lazy `List(children:)` tree), and
`RemoteFileTreeView`/`RemoteFileRow` (the presentation). Only the **provider it
calls** is SFTP-shaped, and that surface is four methods —
`root()`, `list(_:)`, `read(_:limit:)`, `disconnect()`
(`SSHFileSystemProvider.swift:160-186`). Swapping the provider deletes the same
1,409 lines of SFTP the brief targeted while adding ~250 instead of ~700, and it
keeps a tree whose lazy-load re-entrancy, expansion-state identity and
preview-race guards are already correct. Rewriting the view to delete it would
be new code where the deletion target is the transport.

---

## 3. The blocker, narrowed

`one-workspace-source.md` §7.1 and `remote-git-plane.md` §8.2 both state it:

> **Connection ownership.** The review requires a durable per-device connection
> before resource subscriptions, while `withControlChannel`
> (`TermiodClient.swift:1025-1042`) is one-shot. Stage 3 depends on this; Stages
> 1-2 do not, since `fs.list` is a request/response.

Verified: the citation has **not** drifted — `withControlChannel` is at
`TermiodClient.swift:1033-1042` with its doc comment from `:1025`, and the body
is `let transport = try Transport.open(route)` + `defer { transport.close() }`.
Nothing can outlive the closure.

`remote-git-plane.md` §8.1 also claims a second prerequisite — the workspace
reference — and that one **is** resolved: `Checkout` (§1.1). §8.1 should be
struck.

**What the blocker does and does not gate:**

- **Not gated:** `fs.list`, `fs.read`, `git.diff`, `fs.search`. Each is one
  request and its replies on one channel. `fs.search` streams, but the stream
  ends with `fs_searched` inside the same call.
- **Gated:** `subscribe_resource` for `fs:` and `git:`, and therefore live file
  watching, the git changes pane, and `fs.match` coverage. A subscription's
  whole value is that it outlives the request.

So the ordering constraint is: **no `fs:`/`git:` subscription work before a
`TermiodConnection` object exists.** That is Stage 3's prerequisite, and Stage 3
is the fourth thing this plan does, not the first.

One cost the blocker does not name and this plan must: each one-shot call over
SSH is a full connect + hello. Locally that is 0.2 ms; remotely it is 26–33 ms
with a warm ControlMaster (which §1.1 confirms now exists) and 230–300 ms
without. A file tree that expands one directory per click is inside that budget;
a tree that re-lists on every keystroke is not. Stage 1's criterion measures it.

---

## 4. Stages

Each is independently shippable and carries a gate that runs.

### Stage 1 — the Files pane reads a device through `fs.*`; SFTP is deleted

**The single best deletion-to-new-code ratio in this plan**, and it needs
nothing from the blocker.

Today the Files pane has three behaviours (`FileBrowserView.swift:76-88`): the
SFTP tree for a `sftpAlias`, a dead `unavailable(pane:on:)` placeholder for a
checkout on another *device* (the termiod case — the actual bug), and the local
`FileManager` tree. After this stage there are two: local, and `fs.*`.

1. Add `Termiod.listDirectories(route:root:paths:)` and
   `Termiod.readFile(route:path:limit:)` in a new
   `Sources/termio/Terminal/Termiod/TermiodFiles.swift`, built on
   `withControlChannel(caps: ["files"])`, mirroring `TermiodTransfer.swift`'s
   request/`readReply` shape and decoding the `F` chunk header
   (`re:u64be, offset:u64be, last:u8`, `protocol.rs:953-967`).
2. Add `FsListedPayload` / `FsFilePayload` to `IncomingControl`
   (`TermiodClient.swift:885-937`) — additive, `.unknown` stays the default.
3. Re-point `RemoteFileBrowserModel` at the new provider. It takes a `Checkout`
   instead of a `host: String`; `root()` becomes `checkout.root`.
4. `FileBrowserView` renders the tree for **any** `isOnAnotherDevice` checkout;
   the `sftpAlias` branch and the property go.
5. Delete `SFTPClient.swift`, `SSHFileSystemProvider.swift`, and
   `SSHFileSystemProviderTests.swift`. Keep `SSHMux` only if something else
   needs it (it does not — `grep` shows no consumer outside these files).
6. A plain-`ssh` session whose host has no daemon gets the honest empty state
   naming the host, not a blank pane. Offering to install is Stage 4's job,
   because `remote deploy` cannot run from a shipped app today (see §5).

**Gates:**
- `swift build` clean.
- `grep -rn 'SFTP' Sources/ | wc -l` → 0.
- A new `TermiodFilesIntegrationTests`, on the opt-in
  `TERMIO_TERMIOD_TEST_BIN` pattern `TermiodTransferIntegrationTests.swift`
  already establishes: spawn a real daemon on a private socket, list a temp
  tree, read a file back byte-for-byte, and assert the confinement refusal for
  `../escape`. Runs under `swift test` when the env var is set, skips otherwise.
- Unverified-from-code and stated as such until run: the pane renders. Rebuild
  the dev app and capture it with `app-screenshot-debug`.

### Stage 2 — Search and the diff view read a device

`fs.search` (streamed, cancellable) behind `FileSearchView`/`ContentSearch`, and
`git.diff` behind the diff overlay. Still one channel per request; still not
blocked.

**Gates:** ⇧⌘F on a VPS session returns hits with correct paths and line
numbers; cancelling mid-stream produces `fs_searched {canceled: true}`; a diff
for a device path renders in the existing TextKit overlay.

### Stage 3 — the connection is an object (unblocks subscriptions)

`TermiodConnection` per device owning transport, health and reconnect;
`TermiodSessionLink` becomes a client of it; `withControlChannel` becomes a
channel on it rather than a process. `handleStreamEnd` stops calling
`deliverExitLocked` (`TermiodClient.swift:1557-1563`) — a transport failure is
not a process exit.

Then, and only then: `fs:` and `git:` subscriptions, live tree updates, the git
changes pane, `fs.match` coverage.

**Gates:**
- Three panes on one SSH device: `pgrep -lf 'ssh .*<alias>'` shows **one** ssh.
- `launchctl kickstart -k` the daemon with three local panes open: each pane
  shows a state named `daemon_lost`, distinct from `exited`, and `termiod
  tombstones` lists all three with no invented exit status. **Not** "history
  intact" — sessions do not survive a daemon restart and by decision never will
  (`tombstone.rs:184`, burial loop `:194-201`).
- `touch` a file on the VPS; the tree updates without a manual refresh.
- Replay inside the watcher's 300-second linger (`resource.rs:51`) is exact;
  past it, `gap: true` forces a full rescan.

### Stage 4 — the daemon ships and is reachable

Unchanged from `one-path-local-through-termiod.md` Stage 1 except that item 2
(`daemonBinaryPath`) is **already done** (§1.1). What remains: build a universal
`termiod` in `release.yml`, `lipo` it, sign it before the outer seal with
`--options runtime`, carry it through notarization; per-channel `TERMIOD_SOCK`
*and* a per-channel launchd label (`service.rs:26` has exactly one, and
`install()` can only plist `current_exe()` at `:101-107`); install-or-repair the
job on launch; a systemd `--user` unit; and a decision on what a Sparkle update
does to a running daemon.

**Gates:** verbatim from that RFC's Stage 1 criteria, which are already correct
and runnable. `lipo -archs` and the two-plists check run on any checkout; the
notarization checks are CI-only.

### Stage 5 — foreground parity

`foreground_job: bool?` on `SessionInfo`, `foreground_changed` as a debounced
push event, `tcgetpgrp` on the master with a per-platform argv/cwd lookup, argv →
agent mapping staying on the client. Additive within `proto:1`.

**Gates:** `one-path-local-through-termiod.md` Stage 3's four criteria, run in
`termiod`'s CI on both macOS and Linux.

### Stage 6 — git history on the device

`remote-git-plane.md` §5 Stages 1–4 in its own order. §8.1's prerequisite is
already satisfied (§3); §8.2's is satisfied by Stage 3 here.

### Stage 7 — the CLI moves, verb by verb

`one-path-local-through-termiod.md` §7 and Stage 6, unchanged, plus §4's hook
routing. `scripts/termio` becomes a router; `focus` and `notify` stay.

### Stage 8 — the companion, then delete the fork

`one-path-local-through-termiod.md` Stages 4 and 5. Deliberately last: §1.5 of
that RFC establishes that `PTYBridge` uses twelve `PTYProcess` members and three
have no daemon counterpart at all, so this is a rebuild of the mirror, not a
conformance exercise.

---

## 5. Where this disagrees with an existing RFC

1. **`remote-git-plane.md` §8.1 is stale.** It says the workspace reference
   "is unresolved in `one-workspace-source.md` and its review" and that the RFC
   "should not be implemented before it". `Checkout`
   (`DeviceContext.swift:56-101`) resolves it, with `host_id`-first identity —
   which is what the codex review asked for and what `ProjectLocation` did not
   give. Strike §8.1; §8.2 and §8.3 stand.

2. **`one-workspace-source.md` §2's `ProjectLocation` should not be built.** It
   is a two-case enum keyed on `deviceID`; `KnownDevice` + `Checkout` are the
   same information already in the tree, already tested
   (`InspectorCheckoutTests`, 6 tests), and already consumed by every inspector
   pane. Adding a second spelling of the same idea is the fork this plan exists
   to remove. The codex review anticipated exactly this: it proposed
   `WorkspaceReference { deviceID; root }` over the enum, and `Checkout` *is*
   that struct.

3. **`one-workspace-source.md` §5's stage order is inverted.** It puts "delete
   SFTP" last, at Stage 5, behind editing and mutations. Its own review
   disagreed — "SFTP is read-only. A static `fs.list`/`fs.read` tree plus the
   settled plain-SSH install affordance can replace it" — and the review is
   right. Deleting 1,409 lines of the least-tested transport in the app is the
   cheapest correctness win available and it gates nothing.

4. **The brief's "delete `RemoteFileTree.swift`" is wrong.** See §2.3. The SFTP
   plane is 1,409 lines; the tree that renders it is not part of it.

5. **`one-path-local-through-termiod.md` §5.2 item 1 and
   `one-binary-and-a-daemon-that-ships.md` §1 both lead with a bug that is
   fixed.** `daemonBinaryPath()` (`TermiodClient.swift:94-146`) resolves
   `Bundle.main` and then walks up from the *binary*. The remaining half — that
   nothing puts the binary in the bundle — is true and is Stage 4.

6. **`one-path-local-through-termiod.md` Stage 2 item `4a` is done.**
   `multiplexingArguments` ships (`TermiodClient.swift:208-236`, applied at
   `:381`). Stage 3 here inherits only `4b`.

7. **`one-binary-and-a-daemon-that-ships.md` §2.3 stays dead.** Two binaries,
   two names. Reason: B1 and B2 in §1.4. Do not re-propose.

---

## 6. Non-goals

- **QUIC, discovery, `grid_diff` by default, the workspace registry (device
  arch §8.11).** Out, as in the source RFCs.
- **Session survival across a daemon restart.** Decided against
  (`one-path-local-through-termiod.md` §5.2 item 7): a holder process or an
  `exec`-preserving re-exec is a supervisor design, and it would reintroduce the
  failure mode the daemon exists to remove — two processes disagreeing about who
  owns a PTY. Make restarts rare and honest instead.
- **Merging `termio` and `termiod` into one binary.** §1.4.
- **Moving `OSCProgressScanner` or `AgentStatusRules` to the host.** §2.1.
- **A chat/structured-event lens.** Built and reverted three times; the design
  docs record why.
- **Windows.** ConPTY has no controlling terminal and no `tcgetpgrp`. The field
  would be absent, which is the same shape as an old daemon that does not send
  it. One degrade path serves both.
- **Merging `feat/termiod-wss`.** Worth doing, independent of this plan, and not
  sequenced here.

---

## 7. Open questions

1. **Does the one-shot channel cost show up in the Files pane over SSH?** Stage
   1's criterion measures cold expansion. If a warm ControlMaster does not hold
   it under ~50 ms per expand, Stage 3 moves ahead of Stage 2.
2. **What does a plain-`ssh` session's Files pane say, exactly?** Stage 1 ships
   the honest empty state; the install affordance needs Stage 4, because
   `remote deploy` cross-compiles with `env!("CARGO_MANIFEST_DIR")` and `cargo`
   on the user's Mac (`remote.rs:254-268`) and cannot run from a shipped app.
   Nothing publishes a Linux `termiod` artifact today.
3. **Does the watcher's budget need a bound before Stage 3?** The codex review
   raised it: a recursive watch plus a full BFS name-index walk over `$HOME` or
   a large monorepo, alive 5 minutes past the last subscriber
   (`resource.rs:51`). Reaching a machine authorizes reads; it does not
   obviously authorize that.
4. **File identity for the editor and the diff overlay.** `openFileURL`,
   `GitDiffRequest` and `IssuesPanelModel.repoRoot` all store local paths. They
   need `(Checkout, relative path)` before Stage 6. Not before Stage 1 —
   previews stage to a local temp file and already work that way.
5. **Where does `Termiod.isEnabled` stop gating?** Every stage here is inert
   with the flag off. Flipping the default is Stage 8's precondition and needs
   one full release cycle behind it.
