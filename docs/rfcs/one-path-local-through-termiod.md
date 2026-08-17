---
title: One path — local sessions run through termiod too
status: in-review
type: rfc
created: 2026-08-17
updated: 2026-08-17
related:
  - one-path-local-through-termiod.review-claude.md
  - 20260805-termiod-device-architecture.md
  - 20260730-termiod-session-protocol.md
  - remote-to-device.md
---

# One path — local sessions run through termiod too

> Move every server-side responsibility out of the Swift app into `termiod`, delete the in-process PTY path and the app's own control plane, and leave the Mac app as a viewer. This is step 5 of the device architecture's migration ladder, plus the two forks that ladder never named: the inspector panels and the `termio sessions` CLI.

---

## 0. Premise audit — what is still true

The brief for this RFC cited five bugs as one shape. Three are still live; two
were fixed while the argument was being made, and citing them as open would have
been the second-order version of the same mistake. Checked against `main` at
`b4e3e6c`:

| Cited symptom | State | Evidence |
| --- | --- | --- |
| `TERMIO_TERMIOD_REMOTE` silently turns every local terminal remote | **Fixed** | The fallback is gone; the variable survives only as the diagnostic that picks which daemon `logTermiodRoster` inspects (`TermiodClient.swift:25-31`, `TermioStore+Termiod.swift:18-23`) |
| Splitting a remote session drops the new pane on this Mac | **Fixed** | `Session.inheritDevice(from:)` (`Models.swift:344`), called at both split sites (`TermioStore+SplitPanes.swift:48,122`) |
| Image paste has no route to a session on another machine | **Fixed for the device direction** | `upload.open`/`U`/`upload.commit` on their own control channel (`TermiodTransfer.swift`, `protocol.rs:449-514`); three other transfer directions remain unbuilt (device arch §8.10) |
| File tree over SFTP, git through a local `Process`, while the daemon's `files`/`git` planes ship with smoke coverage | **Live** | `SSHFileSystemProvider.swift:249`, `GitService.swift:958-984`; 31 of the daemon's 86 smoke checks cover `fs.*`/`git*` and no Swift file names any of those verbs |
| Agent icon never changes on a termiod session | **Live** | The detector sits inside `if let pty { … }` (`TermioStore+TerminalSurface.swift:390-426`, call at :413); on the termiod path `pty == nil` (:228-231) |

Two of the five landing as point fixes is itself the argument. Each was repaired
where it surfaced; none of them changed the shape that produced it, and the two
that remain are the two nobody could fix locally, because they are not bugs —
they are missing halves.

**The shape, stated once.** A capability is implemented against the object the
app happens to hold — a `PTYProcess`, a local path, a `Process` — and the
termiod path holds a different object, so the capability is absent rather than
broken. Nothing reports it. It is found by a user.

There is also a second fork nobody has written down, and it is larger than the
first: **two CLIs talking to two servers** (§7).

---

## 1. Inventory — what the Swift app does that belongs to a device

The test used throughout, taken from device architecture §4.1: *would two people
watching this session from two different machines expect to see the same
answer?* Yes → the device owns it. No → the viewer owns it.

### 1.1 Session and process plane

| Responsibility | Swift today | termiod today |
| --- | --- | --- |
| Own the PTY, spawn with `login_tty` | `PTYProcess.swift:144-231` (`forkpty`) | **Has it** — `pty.rs:67-167`, same shape, deliberately |
| Non-blocking writes, write backlog | `PTYProcess.swift:478-624` | **Has it** — `pty.rs:208-226` + per-client budget `session.rs:25` |
| Resize / `TIOCSWINSZ`, host-vs-companion ownership | `PTYProcess.swift:626-742` | **Partial** — resize yes (`pty.rs:183`); the two-owner arbitration is a companion concept with no daemon counterpart |
| Reap the child, report exit code + true runtime | `PTYProcess.swift:211-224` | **Has it** — `session_exited`, but the daemon reports no runtime; the client substitutes elapsed-since-attach (`TermiodClient.swift:887-891`) |
| **Foreground process argv** (agent identity) | `PTYProcess.swift:866-874` — `tcgetpgrp` + `KERN_PROCARGS2` | **Missing** — no `tcgetpgrp` anywhere in `termiod/src` |
| **Foreground job present?** (close confirmation) | `PTYProcess.swift:923-927` | **Missing** — `SessionInfo` (`protocol.rs:810-832`) has no such field |
| **Child cwd** (loose-terminal cwd following) | `PTYProcess.swift:805-819` — `PROC_PIDVNODEPATHINFO` | **Missing** — `SessionInfo.cwd` is the *spawn* cwd, never re-read |
| **Child executable identity** (self-update relaunch) | `PTYProcess.swift:827-857` | **Missing**, and acknowledged in the client as a known behaviour gap (`TermioStore+Termiod.swift:93-96`) |
| **Orphan reaping** across an app crash | `PTYProcess.swift:953-…`, matched by `TERMIO_SESSION` + `TERM_PROGRAM=termio` in `ps -axEww` | **Mostly obviated** — a supervised daemon that keeps running has no orphans, and tombstones (`tombstone.rs:66-88`) record what a daemon crash lost. A `SIGKILL`ed *daemon* still strands children; see open question 4 |
| Alt-screen / private-mode tracking for late attach | `PTYProcess.swift:356-441` (`modeResyncPreamble`) | **Superseded** — the `S` snapshot prologue does this correctly (`protocol.rs:398-417`, `tests/snapshot_prologue.rs`) |

### 1.2 Workspace plane (files, git, search)

| Responsibility | Swift today | termiod today |
| --- | --- | --- |
| Directory listing | Local `FileManager`; remote via SFTP over `ssh -s host sftp` (`SSHFileSystemProvider.swift:249`, `SFTPClient.swift`, 1,409 lines together) | **Has it** — `fs.list`, batched + speculative + `seq`-stamped (`protocol.rs:423`); 3 smoke checks |
| File read / preview | Local read; SFTP read | **Has it** — `fs.read` + `F` chunks; 3 smoke checks |
| Filesystem change notification | FSEvents (`FileTreeWatcher.swift`, `FolderEventStream.swift`); **no remote equivalent** | **Has it** — `fs:` resource, debounced, `full_rescan`/`git_meta`, resumable by cursor (`resource.rs`) |
| Filename fuzzy finder | Local walk | **Has it** — `fs.match` with honest `coverage`; 4 smoke checks |
| Content search | Local `git grep`/`grep` via `Process` (`ContentSearch.swift:97-105`) | **Has it** — `fs.search`, streamed + cancellable; 4 smoke checks |
| Git status | `GitService.run` → `/usr/bin/git` (`GitService.swift:958-984`) | **Has it** — `git:` resource, Zed's two-axis vocabulary, delta batches; 6 smoke checks |
| Git diff for one path | `GitService.diffText` | **Has it** — `git.diff`; 1 smoke check |
| Git **history**, commit contents, branch compare, discard, `.gitignore` append, remote/PR URLs, clone info, stall fingerprint | `GitService.swift:80-944` — `log`, `commitChanges`, `compareContext`, `branchCompare`, `suggestedCompareBase`, `discard`, `appendToGitignore`, `remotePage`, `newPullRequestPage`, `gitHubRepoSlug`, `cloneInfo`, `stallFingerprint` | **Missing entirely** — `git.rs` is `run_status` + `run_diff` and nothing else |
| Worktree enumeration and creation | `WorktreeService.swift` → `git worktree list` | **Missing** — device arch §8.11 (workspace registry) |

The gap is narrower than it looks and wider than the panels admit: **the read
path a file tree and a changes pane need is finished and tested on the device
side and unwired on the client side.** The git *history* pane is the part that
genuinely does not exist yet.

Note the live inconsistency this leaves: `FileBrowserView` keys its remote tree
on `session.sshHost` (`FileBrowserView.swift:53,70`) — the plain-`ssh`-in-a-local-PTY
identity — so a *termiod* session on another machine matches neither branch and
falls to `inspectorProjectPath`, which returns nil for a `.host` container
(`TermioStore.swift:413-416`). The pane renders the string `"Remote session"`
(`FileBrowserView.swift:297`) and does nothing. So there are three file-tree
behaviours today (local, SFTP, dead) for two kinds of machine.

### 1.3 Agent plane

| Responsibility | Swift today | termiod today |
| --- | --- | --- |
| Status from hooks | `agent-status.sock` on **this Mac** (`scripts/termio:584`, `HookListener.swift`) | **Has the sink** — `set_status` control op and `E {ev:"status"}` fan-out; nothing routes a hook into it |
| Status from screen rules | `AgentStatusRules` over the viewport, inside `if let pty` (`TermioStore+TerminalSurface.swift:356-366`) | **Missing** — but see §3: this is a viewer job and should stay |
| Status from `OSC 9;4` progress | `OSCProgressScanner`, inside `if let pty` (:303-328) | **Missing** — a byte-stream scan; the viewer sees the same bytes, so it can stay client-side |
| Hand-started agent promotion / demotion | `foregroundProcessArguments()` → `AgentCatalog` (:413-414) | **Missing** — §3 |
| Transcript location and reading | `AgentSessionStore`, local disk enumerate + read | **Reachable via `fs.read`**, unwired |
| Hook installation into agent config files | `HookListener`/`AgentStatusHooks`, writes under the Mac's `$HOME`, bakes an absolute `cliPath` (`HookListener.swift:289`) | **Missing** — §4 |

### 1.4 Client-owned, and must stay that way

Listed explicitly so the refactor has a stopping line: rendering, theme,
palette, fonts; selection, scroll position, viewport; window and split layout;
the project tree's *grouping and naming*; `termio://session/<uuid>` links;
macOS notifications; **and the encoding of a human keypress** (§7.2).

### 1.5 The consumers that break when `PTYProcess` stops being used in-process

This is the part a "delete the fork" plan usually misses. Every reference to
`ptyProcesses` and to `PTYProcess`'s API is a thing that must be replaced, not
merely deleted:

| Site | What it uses | Replacement |
| --- | --- | --- |
| `TermioStore+ProjectActions.swift:690` | `pty.hasForegroundJob` for the close confirmation | §3 — an additive `SessionInfo` field |
| `TermioStore+ProjectActions.swift:609,704,741` | `pty.terminate()` | `kill` (already implemented both sides) |
| `TermioStore.swift:721-731` | `terminateAllSessions` — already detaches termiod links, then SIGTERMs + SIGKILLs every `PTYProcess` | Only the `ptyProcesses` half is deleted; the detach half is the shipped behaviour and stays |
| `CompanionServer.swift:107,145,1096` | `ptyForSession` returns a concrete `PTYProcess` | **The largest single item.** `PTYBridge` (`CompanionServer.swift:931-1041`) is typed on `PTYProcess` and calls `addSink`, `isAlternateScreenActive`, `modeResyncPreamble`, `resizeFromCompanion`, `claimHostOwnership`, `claimCompanionOwnership`. Deleting the in-process path with no replacement removes the iPhone mirror entirely |

The companion dependency is the reason this RFC cannot be a single stage. It is
also, read the other way, the argument for doing it: the phone is a viewer
mirroring another viewer, which §H #9 already condemned, and the only reason
that wire still exists is that the Mac holds a `PTYProcess` the phone can tap.

---

## 2. Target state

```
                 ┌──────────────── device ─────────────────┐
                 │  termiod                                │
   Mac app ──────┤   PTY · process · exit · foreground job │
   iOS   ────────┤   workspace · files · git · search      │
   CLI   ────────┤   session roster · agent status         │
                 └─────────────────────────────────────────┘
   each client:  rendering · theme · selection · viewport · layout · keypress encoding
```

Concretely, when this is done:

1. `Sources/termio/Terminal/Ghostty/PTYProcess.swift` still exists but is used
   by nothing in the session path. (Whether it is deleted or kept for a test
   harness is a later, cheap decision.)
2. `Termiod.isEnabled` does not exist. Opening a session on this Mac and on a
   VPS run the same code, differing only in `TermiodRoute`.
3. The inspector reads the workspace's device. There is no `SSHFileSystemProvider`.
4. `termio sessions` speaks the session protocol, and works on a Linux box with
   no Mac app in sight.
5. A capability added to `termiod` is available on every machine at once. That
   is the whole return on this work.

**What this does not do**, so the scope is honest: it does not add QUIC, does
not add discovery, does not make `grid_diff` a default, does not build the
workspace registry (device arch §8.11 stays where it is), and does not rebuild
the companion as a protocol client — it only stops the companion from blocking
the deletion (§8, Stage 4).

---

## 3. Foreground-process detection on the device

Three separate signals are read from the local PTY today and get conflated. They
have different costs and different owners.

| Signal | Read by | Cost | Needed for |
| --- | --- | --- | --- |
| **Is a job in the foreground?** | `tcgetpgrp(master) != child_pid` | one syscall, no allocation | Close confirmation (`closeConfirmationReason`) |
| **What is the foreground argv?** | `tcgetpgrp` then `KERN_PROCARGS2` | a sysctl walk | Hand-started agent promotion, the sidebar icon |
| **What is the child's cwd?** | `PROC_PIDVNODEPATHINFO` | a kernel struct read | Loose-terminal cwd following |

### 3.1 Cross-platform mechanism

`tcgetpgrp` is POSIX and works against the PTY **master** on both platforms; the
per-platform part is only turning a pid into argv and a cwd.

| | macOS | Linux |
| --- | --- | --- |
| Foreground pgid | `tcgetpgrp(master_fd)` | `tcgetpgrp(master_fd)` |
| argv | `sysctl KERN_PROCARGS2` | `/proc/<pid>/cmdline` (NUL-separated) |
| cwd | `proc_pidinfo(PROC_PIDVNODEPATHINFO)` | `readlink /proc/<pid>/cwd` |

Precedent: this is exactly tmux's split (`osdep-darwin.c` uses `KERN_PROCARGS2`,
`osdep-linux.c` reads `/proc/<pgrp>/cmdline`, both after `tcgetpgrp` on the pty
fd). **Uncertain:** I have read the macOS half working in this repo
(`PTYProcess.swift:859-874` records it as verified) but have not run
`tcgetpgrp` on a Linux ptmx master in this codebase. The migration step below
carries a test for it rather than an assumption.

**Windows: no plan, and no pretence of one.** ConPTY has no controlling
terminal, no process group, and no `tcgetpgrp`. `termiod`'s Unix dependency is
concentrated (`libc::` appears 18× in `pty.rs`, 9× in `client.rs`, ≤2× in each
of `session.rs`/`files.rs`/`paths.rs`/`service.rs`), so a port is bounded — but
this field would be absent there, which is exactly the same shape as an old
daemon that does not send it. One degrade path serves both.

### 3.2 Wire shape

Two additions, both additive within `proto:1` (`protocol.rs` treats unknown
control ops and events as ignorable and `caps` as additive), so no version bump:

```
SessionInfo += foreground_job: bool?          # cheap, on every `list`
E { ev: "foreground_changed", session, pid, argv: [...], cwd? }   # debounced push
```

Three rules the shape encodes:

- **The host reports argv; the client decides which agent that is.** Mapping
  argv → agent needs `AgentCatalog`, which is built from the *user's* manifests
  on the viewer. A host that answered `"claude"` would have to be told about
  every user-defined agent, and would be deciding presentation
  (device arch §4). Sending argv keeps user-defined agents working on a box that
  has never heard of them.
- **It is a push, not a poll.** The Mac polls at 350 ms today because it is
  free in-process. Over SSH, N sessions × 3 Hz is not free, and a poll cannot
  see a transition it lands between. The daemon debounces on its own read loop
  the way the Swift sink does now, and pushes only on change.
- **It never touches `fan_out`.** The sampler runs on the session task's timer,
  never inline in the byte path (§A). A `tcgetpgrp` between two `Write`s would
  put a syscall on the one path the whole architecture exists to keep free.

`foreground_job` rides `list` rather than an event because its consumer asks
once, at close time, and a stale push is worse than a fresh question.

**Skew rule, restated from `remote-to-device.decisions.md` §2:** an absent field
preserves today's no-confirm behaviour. It must never be read as "unknown, so
confirm" — that would tax every close on exactly the sessions the shipped rule
deliberately exempts.

### 3.3 What stays on the client

`OSCProgressScanner` and `AgentStatusRules` read the **byte stream** and the
**rendered viewport**. Every client already receives the bytes (that is the tee)
and every client already has a libghostty holding the screen. Moving them to the
host would make the host parse for a decision a viewer can make from data it
already has, and would put the host's opinion of "working" on the wire where the
viewer's own rules disagree. They stay.

The consequence is worth stating because it looks like an inconsistency: **the
screen-derived status signals already work on a termiod session today** — they
are wired to `pty.addSink` only by accident of where the code was written, not
because they need a PTY. Re-pointing them at the link's `onOutput` seam
(`TermiodClient.swift:882`) is a small change and can land before anything else
in this RFC.

---

## 4. Agent hooks when the agent is on another machine

### 4.1 The chain today

```
agent hook  →  scripts/termio agent report working
            →  nc -U "$HOME/Library/Application Support/termio/agent-status.sock"
            →  HookListener  →  TermioStore
```

Routed by `TERMIO_SESSION`, which the local PTY carries
(`TermioStore+TerminalSurface.swift:199`). Broadcast to both channel sockets so
one installed hook serves a dev and a release app (`scripts/termio:581-587`).

On another machine every link breaks: there is no `scripts/termio`, no
`~/Library/Application Support`, and `TERMIO_SESSION` is deliberately withheld —
"a hook that echoed it back would be reporting to a control socket on the wrong
machine" (`TermioStore+Termiod.swift:68-70`). The exclusion is correct. It is
also the whole problem.

### 4.2 The chain after

```
agent hook  →  termiod set-status "$TERMIOD_SESSION" working
            →  local unix socket, same box
            →  E { ev:"status" }  →  every attached viewer
```

The hook reports to the machine it is running on, over a Unix socket, to a
process that is already there. No SSH, no crypto, no reverse channel, no
listening port. It is the same fan-out `set_status` already performs (smoke
check 46), and `termiod set-status <target> <status> [--title]` already exists
as a subcommand (`main.rs:91-100`) — on the binary that is already deployed.

This also fixes a latent local defect: today a hook reports to the *app*, so a
session that outlives the app has nowhere to report. After the change, status
survives an app quit for the same reason the session does.

**What has to be built:**

1. **Stamp the real session id.** `pty.rs:114` sets `TERMIOD_SESSION=1` — a
   marker, read by nothing. It must carry the session id. This is the whole
   routing key.
2. **Carry the rest of the payload.** The hook contract is not only status:
   `{state, cwd, transcript_path?, conversation_id?, tool?}` (`scripts/termio:566-580`).
   `set_status` carries `status` and `title`. The other four fields need adding
   — additive optional fields on `SetStatus`, or the same fields on a
   `workstream` update op. **Undecided**; the first is smaller and the second is
   tidier, and nothing yet forces the choice.
3. **Map the vocabulary.** The hook says `working|attention|done|idle`; the
   protocol says `working|idle|needs_you|done|failed|unknown`. `attention → needs_you`
   is the only translation. Put it in one place, on the device side, so a
   third client cannot get it wrong.
4. **Install hooks on the device.** `HookListener` writes agent config files
   under the Mac's `$HOME` with an absolute `cliPath` baked in
   (`HookListener.swift:289`). On a device that must happen on the device. The
   cheapest shape that does not invent a mechanism: hook installation becomes a
   `termiod` subcommand (`termiod agent install-hooks`), invoked over the
   existing request plane, writing the same files with `cliPath` pointing at the
   local `termiod`. **The manifest set is still the viewer's** — it is user
   configuration — so the viewer sends the specs and the device writes them.

**`termio agent report` stays exactly as spelled.** It is a published contract
already baked into users' agent configs. It grows one branch: `TERMIOD_SESSION`
set → speak to the daemon; otherwise → the legacy app socket, unchanged. Both
can be true during migration and the broadcast is idempotent.

**Open, and I do not have an answer:** an agent running inside a container or a
sandbox on the device may not see the daemon's socket. Today the same agent
cannot see the Mac's socket either, so nothing regresses — but "the socket is
always reachable from the agent" is an assumption this design rests on and has
not been tested against `docker exec`-style sessions.

---

## 5. Daemon lifecycle — the single point of failure

Making `termiod` the only PTY owner is the one part of this RFC with no
mitigating side. An in-process PTY dies with the app, which is at least a shared
fate the user understands. This section is the list of what must be true before
that trade is acceptable.

### 5.1 What exists

- **launchd (macOS).** `termiod service install|uninstall|status`, `RunAtLoad` +
  `KeepAlive`, boot-out-then-bootstrap on reinstall, `TERMIOD_SOCK` forwarded
  only if the caller pinned it (`service.rs`, three unit tests).
- **Crash accounting.** `tombstone.rs` records `exited` / `killed` /
  `daemon_lost` with identity, last workstream status, and timestamps, capped at
  100, surviving a restart; 7 smoke checks. A session still on the on-disk
  roster when a daemon starts was never buried, so the previous daemon died
  under it.
- **Version negotiation.** `hello` with `[min_proto, proto]`, hard refuse on no
  overlap, additive `caps` (`protocol.rs:28-41`, 4 smoke checks).
- **Backpressure.** Per-client 4 MiB budget, one forced resync, then drop
  (`session.rs:25`, `daemon.rs:414-444`) — §F #10 is closed.

### 5.2 What is missing, and each one is a release blocker

1. **The daemon does not ship.** `scripts/build-app.sh` and
   `.github/workflows/release.yml` do not mention `termiod`. There is a
   `termiod.yml` CI workflow that builds and smoke-tests it, and nothing that
   puts it in the `.app`. Worse, `Termiod.daemonBinaryPath()` defaults to
   `FileManager.default.currentDirectoryPath + "/termiod/target/debug/termiod"`
   (`TermiodClient.swift:58-64`) — a dev-tree path relative to a cwd a
   Finder-launched app does not have. **A released build today cannot start a
   daemon at all.** This must be first.
2. **Dev and release share a daemon.** Nothing sets `TERMIOD_SOCK` per channel,
   and both apps derive the socket from the same `TMPDIR`
   (`TermiodClient.swift:40-53`). Today that is harmless because the flag is off
   by default. After the fork is deleted, launching `termio-dev` shows — and can
   kill — the release app's sessions. Device architecture §9.1 assumes these are
   two devices; the code makes them one. *(Inferred from the path derivation, not
   yet observed; Stage 1's criteria test it.)*
3. **No systemd unit.** `termiod service` bails on non-macOS with a message
   naming what to do by hand (`service.rs:121-127`). A Linux user daemon without
   `loginctl enable-linger` is killed at logout, so sessions silently die between
   SSH connections — the exact promise the product is built on.
4. **Install is not content-addressed.** `remote deploy` `scp`s over
   `~/.local/bin/termiod` (`remote.rs:223-227`), which is the `ETXTBSY` case
   device arch §6 calls out, and the readiness probe is `test -x` with no version
   check (`TermioStore+Termiod.swift:382-399`) — a stale daemon is caught only if
   `hello` outright fails.
5. **Tombstones are produced and never consumed.** No Swift file mentions them.
   A session that died is simply absent from the roster, which is the failure
   mode they were built to prevent.
6. **A transport failure is reported as `exited`.** `handleStreamEnd` →
   `deliverExitLocked(status: 1)` (`TermiodClient.swift:1145-1152`). The pane
   reports a death that did not happen. This is device arch §5.1's `4b`, and it
   is a prerequisite rather than a polish item: a daemon that restarts under a
   running app must not look like every session dying.

### 5.3 Is a tombstone enough?

For the crash case, no — and the doc already knows it (§8.3: "Not done: the last
screen"). A tombstone says *that* a session died and what its status was; the
user's question is *what was on the screen*. Capturing it needs a snapshot
request threaded through the sidecar's shutdown path, which a `SIGKILL` does not
give you. The honest position: the last screen is recoverable on a **clean**
daemon exit and not on a crash, and the tombstone should say which it was rather
than implying an answer it does not have. `daemon_lost` already carries no
invented exit status; the same discipline applies to the screen.

For the **skew** case, tombstones are irrelevant and negotiation is enough. The
failure that actually costs a user is not skew — it is (2) above, two channels
racing for one session table.

---

## 6. Performance — is one more IPC hop acceptable?

Measured (device arch §1, 2026-08-05): connect+hello **0.2 ms**, attach→first
frame **2.2 ms**, echo **~1 ms** above in-process. Against a 16 ms frame budget,
imperceptible. The throughput bench (`bench/bench_100x.py`) puts termiod at
4.4–6.0× tmux and, more tellingly, shows termiod's throughput barely moving
between plain and ANSI-heavy payloads.

That is enough to proceed. Four places where it may not be, ranked by how much
they worry me:

1. **Echo under a flood, which is unmeasured.** The 1 ms figure is an idle-system
   number. The interesting question is p95 keystroke echo *while* the same
   session is emitting at rate — a socket wakeup competing with a read pump
   competing with the sidecar. The daemon's own budget machinery says this was
   thought about; the end-to-end number does not exist. **Criterion:** with a
   `yes` flood running in the same session, p95 echo must stay under 16 ms.
   Anything above that is visible as a dropped frame.
2. **Connection-per-operation.** `withControlChannel` opens, hellos, requests,
   and closes for every `list` and every `kill` (`TermiodClient.swift:733-751`),
   and `TermiodSessionLink` owns a whole transport plus a dedicated
   `Thread` per session (`TermiodClient.swift:1066-1109`). Locally that is
   0.2 ms and a thread; over SSH without a warm ControlMaster it is 216–292 ms
   *per pane*. This is device arch §5.1 `4a`/`4b`, and after the fork is deleted
   it applies to every session on this Mac too.
3. **Startup fan-in.** Surfaces mount lazily (`surface(for:in:)` is called from
   `TerminalPane`'s body), so this is bounded by *visible* panes rather than by
   the restored session count — but a window restored with a 4-way split is
   still 4 connections, 4 handshakes and 4 thread starts on the launch path.
   That is the thing to measure, not the per-attach figure.
4. **The shared pipe.** Files, git, search and uploads ride the same connection
   as keystrokes. The daemon has the head-of-line discipline (credit-of-one,
   PTY frames drained first, 64 KiB caps — `protocol.rs:58-67`) and the client
   currently exercises none of it, because the client uses none of those planes.
   Wiring the panels (Stage 5) is when that discipline first gets tested.

**Where the extra millisecond buys something back:** a session survives the app.
That is not a consolation — an app relaunch today costs a full shell respawn and
a lost screen, which is several orders of magnitude more than 1 ms.

---

## 7. The other fork — two CLIs, two servers

This is a separate axis from the PTY fork and deserves its own stage. It is not
"the CLI is missing a feature"; it is **the CLI is talking to the wrong server**.

```
scripts/termio (shell)  →  session-control.sock  →  TermioStore+SessionControl.swift  (Swift, 894 lines)
termiod        (Rust)   →  termiod.sock          →  termiod/src/                      (Rust)
```

### 7.1 The symptom that names the problem

`termio sessions send` cannot press a bare key. Its delivery is welded
(`TermioStore+SessionControl.swift:400-402`):

```swift
_ = state.send(payload)                      // text through the surface
try? await Task.sleep(for: .milliseconds(40))
Self.pressReturn(on: surfaceHandle)          // then a synthetic Return key event
```

The comment above it explains why the weld is necessary *given the route
chosen*: text goes through `ghostty_surface_text`, so a trailing `\r` in the
payload arrives as a paste rather than a submit, and the submit has to be a real
key event. (The same encoder is why `addSnippetToSelectedSessionPrompt` bypasses
`state.send` entirely and writes raw bytes to the backend —
`TermioStore.swift:353-372`. The workaround already exists in the codebase, one
file away.)

The cost is concrete: Codex's startup trust gate reads *"Press t to trust all;
esc to close"*. `send "t"` presses `t` **and then Return**, which answers the
next prompt too; `esc` cannot be expressed at all. Driving a sibling agent
through that gate failed three times in one session and needed a human at the
keyboard.

`termiod send` has had `--no-enter` since it was written: it writes
`text.join(" ").into_bytes()` to the PTY master and appends `\r` only when asked
(`main.rs:285-296`). Same root cause, third occurrence: the capability exists on
the device and the client path does not reach it.

### 7.2 The boundary — and it is not "move everything"

> **Encoding a human keypress is a viewer job. Writing bytes to a PTY is a
> device job. The current `send` fails because it routes a byte write through
> the keypress path.**

⌘V, ⌃C, a dead key, an IME commit, kitty-protocol modifiers — all of these need
an `NSEvent` and ghostty's key encoder. Rust has no `NSEvent` and must not grow
a model of one; that is a nested window manager wearing a keyboard (§H #7).

A CLI that wants to press `t` does not have a keypress. It has a byte. Routing
it through a surface is not "reusing the input path" — it is asking the human
encoder to reconstruct an intent that was never a keystroke, and the synthetic
Return is the tell.

### 7.3 Verb-by-verb

Classified by the §1 test. "Device" means the answer is the same from any
viewer; "viewer" means it names *this* window or *this* Mac.

| Verb | Asks about | Today | After |
| --- | --- | --- | --- |
| `send` / `answer` | **Device** — bytes into a PTY | surface text path + synthetic Return (`:400-402`) | `termiod send`, verbatim bytes; `\r` appended only when asked |
| `read` | **Device** — what is on that screen | client viewport scrape, requires a live surface (`:589-624`) | daemon snapshot; works for a session no viewer has ever opened |
| `watch` | **Device** — status transitions | `SessionWatchHub` over the app socket (`SessionControl.swift:267-284`) | `subscribe {events:["status"]}` → `E` frames |
| `list` | **Split** | app project tree + status (`:169-218`) | device answers sessions/status/cwd/agent/title (`SessionInfo` already carries all of it); viewer adds grouping and `termio://` links |
| `spawn` / `run` | **Split** | app creates a `Session`, mounts a surface, then sends (`:252-322`) | device `create`; viewer places it in a project and a pane |
| `close` | **Split** | `ptyProcesses[id].terminate()` + remove the row (`ProjectActions:704`) | device `kill`; viewer removes the row. The distinction detach≠kill becomes expressible |
| `agent report` | **Device** | Mac's `agent-status.sock` | `termiod set-status` (§4) |
| `focus` | **Viewer** — selects a pane in *this* window | app | **stays in the app** |
| `notify` | **Viewer** — this Mac's Notification Center | app | **stays in the app** |

Two verbs stay. Everything else moves, and `focus`/`notify` staying is not a
residue — they are the two verbs that fail the two-observers test outright.

**`send` keeps appending Enter by default.** "Type a prompt into a session" is
what the verb documents and what every existing caller relies on; making a
one-character payload silently mean something different would be magic. What
changes is that the Enter becomes a `\r` **byte** instead of a synthetic key
event, so it can be turned off: `send --no-enter`, spelled exactly as
`termiod send` already spells it (`main.rs:88,292`). Byte-exact either way — no
surface, no encoder, no 40 ms sleep. `esc` becomes expressible for the first
time because it is just a byte too.

Three sub-features need naming because they are not verbs:

- **`send --wait`** (`:434-584`) waits on *status resting* plus a screen-change
  fallback. Status is already an `E` event and `wait` is already a control op
  (`protocol.rs:515`, smoke check 48). The screen fallback and the
  stalled-prompt / occupant-gone heuristics are supervision policy and belong to
  the client. **Undecided:** whether `wait`'s `until` set grows to cover the
  stalled case or the client keeps polling; I have not thought this through far
  enough to pick.
- **`watch --state stalled`** is explicitly documented as "a watch-plane signal,
  not a real status" and is computed from repo change plus transcript growth. It
  is derived state over device facts; it stays on the client.
- **Project scoping.** Every request today is resolved to a project via
  `callerProject(session:cwd:)` (`:769-797`). On a device that becomes a
  workspace, which is device arch §8.11 and not this RFC. Interim: the viewer
  keeps doing the scoping and passes an explicit target to the device.

### 7.4 The Linux payoff

`termio sessions list` on a box with no Mac app has no server. After the move it
has one — the same daemon that is already running the sessions. An agent
supervising siblings from inside a VPS session gets the same verbs it has on the
laptop, and `termiod` is one static binary. This is the same return as "local
also goes through termiod", collected on a different surface.

### 7.5 Coexistence during migration

`scripts/termio` is a published contract; `termio agent report` is baked into
users' agent config files by past releases (AGENTS.md names it as the public
hook contract). It cannot be swapped wholesale.

The shape that avoids a flag day: **`scripts/termio` becomes a router, one verb
at a time.**

```
if TERMIOD_SESSION is set (or the resolved target names a device session):
    speak the session protocol   →  termiod
else:
    speak the legacy request     →  app control socket
```

Per verb, the sequence is: implement on the daemon → route the verb → verify
both branches → delete the Swift handler. The Swift control plane's last day is
when its final case is unreachable — `handleSessionControl`'s switch
(`:44-53`) is down to `focus` and `notify`, at which point those two stay and
the streaming `watch` path (`SessionControl.swift:267`) goes with the rest.

**Output shape is the compatibility surface, not just the verb.** `--json`
replies carry `schema_version: 1` and a documented field set; a caller that
parses them (an agent, a script) must not see the shape change under it. Each
moved verb keeps its reply shape byte-for-byte until a deliberate, versioned
change.

---

## 8. Migration

Each stage is independently shippable, independently revertible, and carries a
criterion that can be **run**. "It compiles" is not a criterion anywhere below.

### Stage 0 — clear the field

Not optional and not bookkeeping: the refactor rewrites `TermiodClient.swift`,
`TermioStore+Termiod.swift`, `Models.swift`, `TermioStore.swift`,
`TermioStore+ProjectActions.swift` and `SidebarView.swift`, and **three
worktrees are holding uncommitted or unpushed edits to exactly those files.**

The state, measured (2026-08-17):

| Worktree | Branch | Uncommitted | Ahead of `main` | Pushed |
| --- | --- | --- | --- | --- |
| `termio` (main checkout) | `main` | 16 files | — | — |
| `termio-worktrees/remote-to-device` | `feat/remote-to-device` | 9 files | 0 | no |
| `.claude/worktrees/client-caps` | `feat/client-negotiates-all-caps` | clean | **2** | **no** |
| `.claude/worktrees/device-context` | `feat/device-is-the-context` | 9 files | 3 (merges the above) | no |
| `termio-worktrees/settings-file-watch` | `feat/settings-file-watch` | 10 files | 0 | no |
| `.claude/worktrees/agent-a6effa84…` | `feat/theme-store` | 19 files | 0 | no |
| `.claude/worktrees/editor-scrollaway-header` | — | 2 files | 2 | yes |
| `.claude/worktrees/ios-device-rename` | `refactor/ios-device-concept` | 7 files | 0 | no |

**The finding that changes the order of everything below:** the same change
exists in three places, in three states of commit, and none of it is pushed.

- `feat/client-negotiates-all-caps` holds **1,415 lines across 13 files**,
  committed, never pushed, with no PR. Its two commits are precisely two items
  from this RFC: *"consume the events the daemon was already sending"*
  (negotiates `events`, routes `status`/`writer_changed`/`resized`, decodes
  tombstones — closing §5.2 items 5 and part of 6) and *"put every machine in
  one switcher and retire the word remote"*.
- `feat/device-is-the-context` merged that branch and added 9 more uncommitted
  files on top.
- `feat/remote-to-device` holds an uncommitted **subset** of the same work —
  its untracked `DeviceSwitcher.swift` is byte-identical to the one committed on
  the caps branch — on a base 32 commits behind `main`.

So the largest risk to this RFC is not merge conflict. It is that a
reviewer looks at `main`, concludes the events plane is unwired, and rebuilds
1,400 lines that already exist on a local branch.

**Order, and the test for each:**

1. **Land or kill `feat/client-negotiates-all-caps`.** It is a superset of two
   stages below and it is committed. Rebase onto `main` (7 commits), push, PR.
   Its own tests (`TermiodEventTests`, `TermiodStatusTests`, +51 lines of smoke)
   are the criterion.
2. **Collapse the two duplicates into it.** `feat/remote-to-device`'s
   uncommitted work is a subset — discard it after confirming so with a diff,
   do not merge it. `feat/device-is-the-context`'s 9 files are the only unique
   content; commit them on top of (1).
3. **Land or discard the unrelated dirty worktrees.** `theme-store` (19 files,
   uncommitted, with `docs/rfcs/theme-store.md` existing untracked in *two*
   worktrees), `settings-file-watch` (10), the `main` checkout's own 16, and
   `editor-scrollaway-header` (2 files that do not match its branch name, one of
   them an iOS app icon — inspect before assuming it is wanted).
4. **Close the noise PRs.** PR #317 carries six `__pycache__/*.pyc` files it
   should not; PR #310 is this RFC family's own predecessor and should merge or
   close before a second RFC lands beside it.

**Criterion for Stage 0:** `git worktree list` shows no worktree with
uncommitted changes to any of `Sources/termio/Terminal/Termiod/*`,
`Sources/termio/TermioStore/*`, `Sources/termio/App/Models.swift`,
`Sources/termio/Terminal/Ghostty/PTYProcess.swift`; and every branch that is
ahead of `main` is either pushed with a PR or deleted.

**One thing Stage 0 does *not* need to clear.** No uncommitted change and no
open PR touches `PTYProcess.swift`, `TermioStore+TerminalSurface.swift`,
`GitService.swift`, or `FileBrowser/`. Only PR #73 touches a refactor-critical
file at all (`TermioStore.swift`). The collision is concentrated in the
*device-client* files, not the PTY and panel files — the brief assumed the
opposite, and planning around the wrong set would have serialised work that can
run in parallel.

### Stage 1 — the daemon ships and is reachable

Nothing below is safe until a released app can start a daemon.

1. Build `termiod` in `release.yml` and copy it into the bundle
   (`Contents/Resources/termiod` or `Contents/MacOS/`); sign and notarize it
   with the app.
2. `daemonBinaryPath()` resolves the bundled binary first, then
   `TERMIO_TERMIOD_BIN`, and only then the dev tree.
3. Derive `TERMIOD_SOCK` per channel so `termio-dev` and `termio` are two
   devices, as device arch §9.1 already assumes.
4. Ship the systemd `--user` unit + `enable-linger` guidance as
   `termiod service install` on Linux.

**Criteria (run, not read):**
- On a machine with no checkout: install the notarized `.app`, launch it from
  Finder, open a terminal, and `termiod service status` reports a live socket;
  `ps -o comm= -p <daemon pid>` resolves to a path inside the `.app` bundle.
- `codesign -vvv --deep --strict termio.app` passes with the daemon inside.
- Launch `termio-dev` and `termio` together; each `termiod list` returns a
  disjoint session set, and `hello_ok.host_id` differs between them.
- On Linux: `termiod service install`, `loginctl terminate-user $USER`, log back
  in, `termiod list` still shows the session created before logout.

**Rollback:** the flag is still off by default; revert the bundling commit.

### Stage 2 — the connection is an object

Device arch §8.4. Prerequisite for every later stage because it is what stops a
daemon restart from reading as N session deaths.

- `4a`: put `ssh_multiplex_args()`'s option set — plus the `BatchMode` /
  `ConnectTimeout` every other ssh call site already sets and this one does not
  — on the app's own ssh invocation.
- `4b`: a `TermiodConnection` per device owning transport, health and reconnect.
  `TermiodSessionLink` becomes a client of it. `handleStreamEnd` stops calling
  `deliverExitLocked`.

**Criteria:**
- With three panes open on one SSH device, `pgrep -lf 'ssh .*<alias>'` shows
  **one** ssh process, not three.
- `launchctl kickstart -k gui/$UID/sh.termio.termiod` while three local panes
  are open: no pane shows "process exited"; all three show a reconnecting state
  and then repaint from a snapshot with their shell history intact.
- `termiod list` before and after that restart returns the same session ids.

**Rollback:** self-contained; the link keeps working if the connection object is
reverted.

### Stage 3 — foreground parity (§3)

`foreground_job` on `SessionInfo`, `foreground_changed` as an event, the
Linux/macOS split behind one trait, argv → agent mapping staying on the client.

**Criteria:**
- New smoke checks: with `sleep 60` running, `list` reports
  `foreground_job: true`; at a bare prompt, `false`. Run in `termiod`'s CI on
  both macOS and Linux — this is the test that settles §3.1's uncertainty.
- Start a shell session on a VPS, run `sleep 60`, press ⌘W: the same
  confirmation a local shell gives today.
- Type `claude` at a prompt in a *termiod* session; the sidebar row's icon
  becomes Claude's within 1 s, and reverts on exit. (This is the bug from §0
  that has no fix without this stage.)
- A daemon built without the field: closing a shell with a live job shows **no**
  dialog — today's behaviour, not a blanket confirm.

**Rollback:** additive field; an app that ignores it behaves as before.

### Stage 4 — the companion stops depending on `PTYProcess`

The blocker identified in §1.5. `PTYBridge` takes a protocol
(`sink`, `write`, `resize`, `alternateScreenActive`, `resyncPreamble`) that both
`PTYProcess` and `TermiodSessionLink` satisfy. Not a rebuild of the companion —
only enough to unblock the deletion.

**Criteria:**
- With `TERMIO_TERMIOD=1`, open a session on the phone, type, resize, background
  and foreground the app: same behaviour as with the flag off. Verified on a
  real device, not the simulator.
- `grep -rn 'PTYProcess' Sources/termio/Companion/` returns nothing.

**Rollback:** the protocol has one other conformer; revert to the concrete type.

### Stage 5 — delete the fork

Only now. Remove `Termiod.isEnabled` and every branch on it, the in-process
`PTYProcess` construction, the flag-off alert (`TermioStore+Termiod.swift:471-477`),
and the `ptyProcesses` half of `terminateAllSessions` (the detach half already
ships).

**Criteria:**
- `grep -rn 'TERMIO_TERMIOD\b' Sources/ | wc -l` → 0.
- `grep -rn 'PTYProcess(' Sources/ | wc -l` → 0.
- Open a local terminal, run `sleep 300`, quit the app, relaunch: the pane
  reattaches to the **same pid** (compare `termiod list --json`) with its screen
  intact.
- `swift test` green, including `SplitTreeTests` and the status tests.
- Screen-recorded pass of: new terminal, new agent session, split, close with a
  running job (dialog), close idle (no dialog), agent self-quit reverting to a
  shell.

**Rollback: this is the one stage that is hard to revert**, because it deletes
the alternative. Mitigation is sequencing, not a switch: Stages 1–4 each remove
a reason the flag existed, so by the time this lands the flag has been on by
default for a full release cycle. Concretely — **ship Stage 4 with the flag
defaulting to on and the env var able to force it off**, run one release, then
delete in Stage 5. The escape hatch is a release rollback, not a runtime flag.

### Stage 6 — the CLI moves, verb by verb (§7)

Order chosen so the highest-pain verb lands first:

1. `send` / `answer` — byte-exact injection.
2. `read` — daemon snapshot.
3. `watch` — `subscribe`.
4. `list` — device fields from the daemon, grouping from the viewer.
5. `spawn` / `run`, `close` — split as in §7.3.
6. `agent report` → `set-status` (§4), and hook installation on the device.

**Criteria:**
- The one the brief asked for, made mechanical: create a session running
  `cat -v`; `termio sessions send --no-enter <s> t` puts exactly `t` on the
  screen with no `^M` and no second line, and plain `termio sessions send <s> t`
  still shows `t` followed by a submit (the unchanged default). Then, on a real
  Codex startup gate, `termio sessions send --no-enter <s> t` dismisses the
  trust prompt and leaves the next prompt untouched, and
  `termio sessions send --no-enter <s> $'\e'` closes it.
- `termio sessions read <s>` returns the screen of a session that has **never**
  been opened in a window (today: `not_live`).
- On a Linux box with no Mac app: `termio sessions list` and
  `termio sessions send` work against the local daemon.
- Old-shape check: `termio sessions list --json` output is field-identical to
  the pre-move build for the same session set.
- After the last move, `handleSessionControl`'s switch contains `focus` and
  `notify` and nothing else.

**Rollback:** per verb — the router's legacy branch is still there until the
Swift handler is deleted, and deleting each handler is its own commit.

### Stage 7 — the panels move (device arch §8.9)

File tree, search, and git status/diff read the workspace's device through the
`files`/`git` planes. `SSHFileSystemProvider` and `SFTPClient` (1,409 lines) are
deleted. `GitService`'s 12 history/compare/remote verbs are the part with no
device counterpart and stay local until the daemon grows them — say so in the
UI rather than showing an empty pane.

**Criteria:**
- The file tree renders for a session on a VPS, and expanding a directory that
  has never been listed costs one round trip (measure with a request log).
- `touch` a file on the VPS; it appears in the tree without a manual refresh.
- ⌘⇧O finds a file on the VPS by name, and shows "still indexing" rather than
  silently missing files while `coverage < 1.0`.
- The git changes pane shows a VPS worktree edit with the correct two-axis
  status.
- `grep -rn 'SFTP' Sources/ | wc -l` → 0.

---

## 9. Risks and rollback

| Risk | Why it is real | Mitigation |
| --- | --- | --- |
| **The daemon becomes release-critical and it has never shipped** | §5.2 item 1: the release pipeline does not build it and the fallback path is a dev tree | Stage 1 first, with a criterion that runs on a clean machine from a notarized build |
| **A daemon crash loses every session at once** | Shared fate is replaced by a single point | launchd `KeepAlive` (shipped) + tombstones (shipped, must be consumed) + the honest admission that the last screen is unrecoverable on `SIGKILL` (§5.3) |
| **Stage 5 is not revertible** | It deletes the alternative | Flag-on-by-default for one release before deletion; rollback is a release rollback |
| **Rebuilding work that exists on an unpushed local branch** | 1,415 committed lines on `feat/client-negotiates-all-caps` with no PR | Stage 0 item 1, before anything else |
| **The companion breaks silently** | `PTYBridge` is typed on the concrete class and no test covers the phone | Stage 4 gates Stage 5, with a real-device criterion |
| **Anti-100× regression** | Adding foreground sampling and a status source to the daemon puts new work near the read loop | Every new sampler runs on its own task; the criterion is the existing `bench_100x.py` staying within its current band, run in CI before and after Stage 3 |
| **`termio sessions` breaks an agent's script** | It is a published contract with a documented JSON shape | Per-verb routing with the legacy branch alive; field-identical `--json` output as a Stage 6 criterion |
| **Dev and release fight over one session table** | Same socket derivation (§5.2 item 2) | Stage 1 item 3, with a criterion that checks `host_id` differs |
| **Panels regress for local projects** | Stage 7 replaces a working local path with a round trip | `fs.list` replies are `seq`-stamped and clients cache indefinitely (§C.12), so a visited directory is 0-RTT; the criterion measures the cold expansion, and the local socket makes it sub-millisecond |

---

## 10. Open questions

1. **Hook payload shape (§4.2 item 2).** Extend `SetStatus` with four optional
   fields, or add a `workstream` update op? Nothing forces the choice yet.
2. **Can an agent in a container reach the daemon socket?** The whole hook design
   assumes yes. Untested against `docker exec`-style sessions. Nothing regresses
   if the answer is no — the Mac's socket is equally unreachable today — but the
   design would need a second route.
3. **`send --wait`'s stalled-prompt heuristic (§7.3).** Grow `wait`'s `until`
   set, or keep polling on the client? Undecided.
4. **What replaces `reapStrayOrphans`?** A supervised daemon should have no
   orphans, but *the daemon itself* can be `SIGKILL`ed and leave its children
   re-parented to launchd. The current sweep matches on `TERMIO_SESSION` +
   `TERM_PROGRAM=termio`; the daemon would need its own equivalent, and I have
   not checked whether `KeepAlive` restarting the daemon adopts or races them.
5. **Does `PTYProcess` survive at all?** After Stage 5 nothing constructs it. It
   holds real learning (the `forkpty` shape, the non-blocking write backlog),
   most of which `pty.rs` already mirrors. Delete or keep as a test fixture —
   cheap either way, no need to decide now.
6. **Linux `tcgetpgrp` on the ptmx master (§3.1).** Strong precedent, not
   verified here. Stage 3's CI criterion is the verification, but if it fails the
   Linux fallback is unclear — reading `/proc/<child>/stat`'s `tpgid` field is
   the candidate and has not been checked.
7. **Git history on the device.** 12 `GitService` verbs have no daemon
   counterpart. Port them, or accept that history is a local-project feature
   until someone asks? The read-only-by-design rule (§C.13) covers *mutation*;
   it says nothing about history, which is read-only and genuinely missing.
8. **When may the app require a `hello`?** Deprecation policy for v0-only
   clients is listed as a human product call in the protocol doc's top five and
   is still open. It becomes load-bearing the day the daemon ships in the app,
   because then the version pair is *ours* and the skew window is a user's
   upgrade lag rather than a developer's checkout.
