# termiod v1 — Handoff for the next orchestrating agent

You are taking over an in-progress effort on **termiod**, termio's durable PTY
session host. Your job is to keep **orchestrating sibling agents** (Codex, other
Claude sessions) to build out **v1** — the authoritative-VT snapshot layer
(issue #181) — while preserving the architecture and discipline established so
far. Read this whole file before dispatching anyone.

- **Branch / PR:** everything lives on `termiod/rust-poc` (draft PR **#177**).
  Tip at handoff: **`1aa8d23`**. Worktree:
  `/Users/yuanjiwei/Documents/GitHub/termio/.claude/worktrees/termiod-rust-poc`.
  The main checkout is on `main` and has *unrelated* modified iOS files — **do
  not touch them**; do all termiod work in the worktree.
- **Epic:** #164. **Done:** #179, #180. **Active:** #181 (spike complete, Phase 1
  next).

---

## 1. What termiod is (the thesis you must preserve)

`termiod` is a durable session host: it owns every PTY, and Mac/iOS/CLI/remote
are all **attach clients**. Detach ≠ kill. The design is written up in
`docs/design/termiod-session-protocol.md` (the spec) and
`termiod-session-mux.md` (product/competitive). Read §A of the protocol doc.

**The one load-bearing idea — input replication, not state sync.** A VT parser
is a deterministic state machine: same bytes in → same screen out. The host
keeps every viewer consistent by **shipping the byte log** (raw PTY bytes teed
to every client, each replays through its own libghostty), *not* by shipping a
server-maintained grid. This is what makes termiod fast; tmux does the opposite
(parses every byte into a grid) and pays a 16–24× tax (benchmarked, see below).

### Non-negotiable invariants (do not let any agent violate these)

1. **Anti-100× invariant:** *byte delivery MUST NOT block on host-side VT parse.*
   `session.rs::fan_out` is copy/refcount + socket only — it never inspects byte
   contents. The v1 VT is a **sidecar**, consulted only to build snapshots, off
   the hot path. Any per-frame grid encoder between PTY and pipe rebuilds the
   tmux tax and is rejected.
2. **State sync only at boundaries:** the `S` snapshot fires on attach / resize /
   resync (and a periodic keyframe in the v1.1 diff mode) — never per frame.
3. **Wire protocol is transport-agnostic and versioned:** same framed messages
   over Unix socket / SSH / (later) QUIC. Don't change framing without a `proto`
   bump. SSH is the trust plane; QUIC is a later performance plane with borrowed
   identity (no DIY PKI).
4. **Single writer, many readers.** Observers never claim the write token.
5. **No nested window manager** in the host. One PTY per session.

---

## 2. What's already done (with commits, all on `termiod/rust-poc`)

| Commit | What |
| --- | --- |
| `4ebd51d` | Design reframed as input-replication vs state-sync; anti-100× invariant (§A); `S` snapshot triggers (§C.6) |
| `d568a22` | **Anti-100× benchmark** — `termiod/bench/bench_100x.py` (+ README). Result: termiod tee is **4–6× tmux on the Mac, 16–24× on the VPS** (parse tax is CPU-relative — memcpy tee vs CPU-bound parser). tmux loses ~50% plain→ANSI; termiod holds. |
| `1373646` | Folded in a Codex review vs Mitchell Hashimoto's Superlogical talk: dimension-mismatch correctness req (§C.5), unbounded-backlog (§F #10), resize-barrier (§F #11) |
| `c87a034` | **#180** `bytes::Bytes` zero-copy fan-out + bounded 4 MiB per-client backlog. Kills the (C+2)×n copies AND unbounded memory. Slow clients dropped + logged. |
| `ae6f4f8` | `opt-level=3` re-bench → no material change (confirms hot path is memcpy/syscall-bound, not compute-bound) |
| `75b1e58` | **#179** non-interactive `attach --observe` mode (pure copy-to-stdout, never claims writer, no stdin-EOF exit). Fixes the 0-bytes-over-SSH bug; unblocks scripting + the live backlog-drop test |
| `f677026` | #181 spike: evaluated `alacritty_terminal` vs `libghostty-vt`. Standalone proof `termiod/spike/vt-sidecar` (alacritty). Report: `docs/design/termiod-vt-sidecar-spike.md` |
| `bd1ead5` | Corrected §C.6: libghostty-vt 1.3.2 cells are **opaque** — no wire-ready 16-byte cell; conversion required regardless of engine |
| `5e956aa` | **DECISION:** v1 VT engine = **libghostty-vt** (overrode the spike's alacritty pick) — see §3 |
| `1aa8d23` | **#181 Phase 0 done:** libghostty-vt FFI build proof `termiod/spike/vt-ffi` — builds, FFIs from Rust, produces the correct snapshot, cross-compiles to aarch64-musl. Verified independently on both Mac and VPS. |
| `bc36438` | **#181 Phase 1a (part 1):** spike promoted to a real `termiod/vt` library crate (safe `VtTerminal` wrapper, vendored libghostty-vt, dual-target build.rs). |
| `9f539b8` | **#181 Phase 1a done:** per-session VT sidecar thread (in-band FIFO commands — the snapshot request is an exact byte boundary, unit-proven), `S` frame (versioned 16-byte wire cells) + `ready` event, capability-gated with ring-replay fallback; `fan_out` untouched on the hot path. Verified independently: Mac (4+2 tests, 33 local + 8 remote smoke, musl cross-build) and ukvps native (build, tests, 33 smoke). |
| `c3ba217` | **#181 Phase 1b (part 1):** resize is a snapshot barrier — `pty.resize` failure now surfaced (typed `internal` error, dims/events untouched, unit-proven via non-PTY fd); on success the sidecar `Resize` + per-client `Snapshot` requests ride the FIFO adjacently, snapshot clients re-enter `SnapshotPending`; `request_id` versioning drops stale in-flight snapshots (fixes the attach-snapshot × resize race). Decision: **every** successful `S` is followed by `ready`. |
| `74f0c7c` | **#181 Phase 1b (part 2):** writer failover size reclaim — the promoted writer receives `ResizeClaim` naming itself; the reference client answers by re-sending its size as `R`, which triggers the barrier. Verified independently: Mac (5 tests, 38 smoke, 8 remote, musl cross) and ukvps native (5 tests, 38 smoke). **New gotcha:** a daemon auto-started by an earlier smoke run keeps running the OLD binary image — `pkill -x termiod` before re-running smoke on a rebuilt binary (bit us on ukvps: barrier S never arrived because the live daemon predated the barrier). |
| `cee565e` + `7998539` | **#181 Phase 1c done:** `attached` carries the authoritative PTY `rows`/`cols` (serde-additive, old payloads default 24×80; values taken atomically with registration via `AddClientReply`, emitted before the writer's post-attach resize); observer CLI prints a one-line size-mismatch notice; smoke asserts `attached` dims == `S` header dims. Verified independently: Mac (6 tests, 40 smoke, 8 remote, musl cross) and ukvps native (6 tests, 40 smoke). |
| `c48ff9c` + `476c68e` | **#181 Phase 1d done:** staged scrollback — libghostty-vt history read via `GHOSTTY_POINT_TAG_HISTORY` + `ghostty_terminal_grid_ref` (untracked refs, safe inside the synchronous sidecar Snapshot command); captured at the same FIFO boundary as `S`, capped `SCROLLBACK_STAGE_MAX_BYTES` = 1 MiB newest-first with truncation logged; new `H` frame (0x48, ≤64 KiB chunks, host→client only) gated on `snapshot`+`scrollback` caps; delivery `attached→S→ready→H…` interleaved with live `D` via a one-chunk-per-loop `yield_now` select arm; H bytes ride the 4 MiB backlog accounting; resize barrier cancels unfinished history (restaging deliberately deferred). Spec C.2/C.6 updated. Verified independently: Mac (8+3 tests, 42 smoke, 8 remote, musl cross) and ukvps native (8 tests, 42 smoke). |
| `faeb16d`…`544c51f` | **#181 Phase 1e done (v1.1 G diffs):** `take_damage()` in the vt crate (global+per-row damage read/clear); `G` frame (0x47, versioned: frame_seq u32 monotonic, cursor, dirty rows × 16-byte wire cells) gated on `grid_diff` (requires `snapshot`, dropped at hello otherwise); single ordered `SidecarResult` channel (Snapshot/Grid/Keyframe — two channels could let a G overtake its S and regress rows); grid clients skip raw-D fan-out entirely (zero backlog reserve), pending clients discard pre-boundary G; keyframes every 256 flushes (env `TERMIOD_KEYFRAME_EVERY` for tests) as S+`ready`; damage encoding is zero-cost with no grid client (`SetGridDiff` interest toggle); sidecar death disconnects grid clients with a typed retryable error; CLI `attach --grid-diff` (raw D stays default). Verified independently: Mac (10+4 tests, 48 smoke, 8 remote, musl cross) and ukvps native (10 tests, 48 smoke). |

All of #180 and #179 were **deployed to the VPS `ukvps` and tested live**:
no throughput regression (16–24×), the backlog drop fires ("dropping slow client
… exceeded 4 MiB") with RSS bounded, observe-over-SSH delivers full output.

---

## 3. Key decisions and their rationale (do not re-litigate)

- **VT engine = libghostty-vt, NOT alacritty_terminal.** The spike recommended
  alacritty (builds without Zig), but the user overrode it on a **correctness**
  ground: every termio client *is* libghostty (Mac embeds it, iOS mirrors it), so
  the host authority must run the **same** VT or the synchronized-state-machine
  model breaks (grapheme/width/autowrap/escape divergence → the host's snapshot
  wouldn't match what a client renders). Fidelity parity is worth the Zig/FFI
  cost. Proven: the FFI snapshot resolves the green cell to Ghostty's real
  `rgb(181,189,104)`, identical on Mac and Linux.
- **Wire cell is engine-independent.** libghostty-vt cells are opaque; there is a
  conversion step. Keep it behind a neutral boundary so the engine stays swappable.
- **Develop the Linux daemon natively on Linux (the user's steer).** Cross-from-Mac
  was a POC shortcut; for the run/debug/integrate loop, build on the target.
  libghostty-vt builds natively on `ukvps` in ~3 min (Zig is a cross-compiler, so
  cross also works, but native is the dev workflow going forward). Note termiod
  *also* builds for macOS-arm64 (it's the local host too — "local = remote to
  localhost"), so **both targets must keep working**.

---

## 4. Environment and artifacts

**Worktree layout** (under the worktree root):
- `termiod/` — the daemon+client crate (`src/{daemon,session,client,protocol,pty,remote,main,paths}.rs`).
  - `smoke_test.py` (27 checks), `remote_smoke_test.py` (8 checks) — keep green.
  - `bench/bench_100x.py` (+ `README.md`) — the anti-100× benchmark.
  - `spike/vt-sidecar/` — alacritty proof (reference; NOT the chosen engine).
  - `spike/vt-ffi/` — **libghostty-vt FFI proof (the chosen engine)**. `build.rs`
    shells Zig (herdr's pattern), bindgens `include/ghostty/vt.h`, links the
    static lib. Vendored libghostty-vt `1.3.2-HEAD-+c5a21edfc`.
- `docs/design/termiod-session-protocol.md` — **the spec** (§A invariant, §C.5/§C.6
  terminal plane, §D transports/QUIC, §E matrix, §F risks — incl. #9 pipe-mode,
  #10 backlog, #11 resize, and the general v1 plan). Read this first.
- `docs/design/termiod-session-mux.md`, `termiod-vt-sidecar-spike.md`.

**Toolchains:**
- Mac Zig 0.15.2: `~/.local/share/termiod-toolchains/zig-0.15.2/zig`. Build the FFI
  crate with `ZIG=<that> DEVELOPER_DIR=/Library/Developer/CommandLineTools cargo …`
  (the `DEVELOPER_DIR` avoids Xcode 26.4's arm64e-only SDK).
- VPS `ukvps` Zig 0.15.2: `~/.local/share/zig-0.15.2/zig`; Rust via rustup
  (`~/.cargo/bin`); `aarch64-unknown-linux-musl` target + `libclang` installed.
  The FFI crate is rsynced at `ukvps:~/vt-ffi/` and builds natively:
  `cd ~/vt-ffi && ZIG=$HOME/.local/share/zig-0.15.2/zig ~/.cargo/bin/cargo run --locked --target aarch64-unknown-linux-musl`.
- `build.rs` pins Zig to exactly 0.15.2 and only allows macOS + aarch64-musl
  targets (rejects `linux-gnu` — build for musl on the VPS).

**Deploy path:** `termiod remote deploy ukvps` cross-compiles the daemon
(aarch64-musl) from the Mac and scps it. Stop the running daemon first (`ssh ukvps
pkill -x termiod`) or scp fails with `ETXTBSY`. SSH host alias `ukvps`
(130.162.188.52, user ubuntu) is in `~/.ssh/config`.

**Live sessions at handoff** (see §5 for how to use them):
- `terminal@f01bf339` — a persistent **SSH shell into ukvps** (the Linux dev session).
- `codex@48692b12` — **warm, unblocked, full context** (did #180, #179, the reviews,
  the VT spikes). **Reuse this one** for continuity.
- `codex@651402ce` — did the SIMD + Mitchell-talk reviews.

---

## 5. How to orchestrate the sibling agents (read carefully — real gotchas)

You drive siblings with the `termio sessions` CLI (scoped to this project;
`--json` for machine output). Core verbs: `list`, `spawn "<prompt>" --agent codex`,
`send <handle> "<text>"`, `read <handle>`, `run "<cmd>"`, `watch`, `focus`, `close`.

**Discipline that worked and you should keep:**
1. **Prefer reusing `codex@48692b12`** (warm + full context) over spawning fresh —
   see the hook-gate gotcha below.
2. **Dispatch with `send --wait --timeout <ms>`.** Long tasks usually **time out**
   the wait (reply: "still working after the wait") — that's fine; then **poll**
   `termio sessions list --json` until the session's status ≠ `working`, and read
   the result. A background poll loop works well.
3. **Read the reply from the Codex transcript, not the screen.** The screen
   (`read`) only shows the tail. Get the latest file at
   `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` and extract the last `assistant`
   message (the Python one-liner used throughout: iterate lines, JSON-parse,
   collect `payload.role=="assistant"` text, print the last).
4. **ALWAYS independently verify Codex's claims** before trusting/reporting —
   rebuild the crate, re-run the proof/smoke tests yourself, review the diff.
   Every Codex deliverable this session was independently re-run (and one build
   caveat — `ZIG`/`DEVELOPER_DIR` env — was caught this way).

**CRITICAL GOTCHA — the Codex hook-trust gate.** A freshly `spawn`ed Codex boots
into a "⚠ N hooks need review / Press t to trust all" gate (termio's own
`agent report` hook, "modified since last trusted"). **You cannot clear it with
`termio sessions send "t"`** — `send` appends a Return, so `t\n` = trust-all
*then* the Return triggers "enter to review hooks", reopening the gate. It needs a
**bare keypress**. Workarounds: (a) **reuse an already-unblocked Codex** (best), or
(b) `termio sessions focus <handle>` and ask the **human to press `t` once** in the
pane, then re-send your task (the spawn's queued prompt is usually lost in the
churn — resend it). This bit us twice; budget for it.

---

## 6. Next steps — Phase 1 (issue #181)

**ALL of Phase 1 is DONE (2026-07-31, single day, phases 1a–1e — see the §2
table for commits and verification).** The #181 protocol ladder shipped whole:
`S` snapshot-on-attach + `ready` (1a) · resize-as-barrier + TIOCSWINSZ
surfacing + writer-failover size reclaim (1b) · authoritative `rows`/`cols` in
`attached` (1c) · staged scrollback `H` frames (1d) · capability-gated `G`
dirty-row diffs with keyframes, the v1.1 plane (1e). Suites: 48 local + 8
remote smoke, 10+4 unit; everything dual-verified on macOS-arm64 and native
aarch64-musl (`ukvps`). Hands-on Mac→Linux test steps: `DEPLOY.md`.

### Remaining directions (each needs a human product call before dispatch)

1. **`termiod stdio` bridge — DONE (`cbe9e23`, 2026-08-01).** `termiod stdio`
   is a transparent byte relay splicing stdin/stdout to the local daemon socket
   (no frame parsing of its own); run as `ssh <host> termiod stdio` it puts the
   framed protocol itself on the SSH pipe. Deterministic Rust integration test
   (`tests/stdio_bridge.rs`) drives hello → attached → S → ready → live D
   through the bridge and asserts byte-identical ordering — the §C.9 claim is
   now real. The daemon auto-starts like every other verb. **Next, to make
   remote work IN THE APP** (the differentiated demo — agent runs on a Linux
   box, you attach from the Mac): **DONE (`b91d180`, 2026-08-01).**
   `TermiodSessionLink` now has a transport seam (`Termiod.Transport`): local
   Unix socket, or an SSH pipe to `ssh <host> termiod stdio`. Set
   `TERMIO_TERMIOD_REMOTE=<host>` with the flag on → new sessions run on that
   Linux host, the Mac attaches over SSH; the whole M2/M3 client (attach,
   snapshot repaint, detach-not-kill) reused unchanged, only the pipe differs.
   Verified end-to-end against the real `ukvps` VPS: the Swift SSH transport
   does hello → attached → S snapshot (24×80, decoded) → ready through
   `ssh ukvps termiod stdio`. System OpenSSH is the trust plane; termio never
   ships an SSH server (§H #8). **Remaining for the app remote demo:** a real
   UI to pick the host per session (today it's one env-configured host); remote
   sessions currently spawn a plain login shell (agent-on-remote — e.g. `claude`
   on the VPS — needs argv/env wired for the remote, and the agent installed
   there); the live GUI recording.
   **UI landed (`55b2734` + `8e86866`, 2026-08-01):** per-project `+` ▸
   **New Remote Terminal** submenu from `SSHConfig.hosts()` (~/.ssh/config, the
   single host source), opening a `.terminal` session on the picked host;
   per-session `Session.termiodRemoteHost`/`termiodRemoteCwd` (persisted,
   `decodeIfPresent` back-compat) replace the global env as the source of truth
   (env stays a fallback). `ensureRemoteReady` deploys termiod if missing +
   reachability-gates before attach, with a HUD and typed failure alerts.
   Project right-click **Clone on Remote…** → pick host → `ssh <host> 'cd ~ &&
   git clone <origin> <name>'` (origin/unpushed-count via new
   `GitService.cloneInfo`; unpushed-commits warning; `BatchMode=yes`; captures
   the clone's absolute path via `printf $PWD/<name>` since the daemon chdir is
   raw) → opens a remote terminal in the cloned dir. Flag-off/local paths stay
   byte-identical (all gated behind `Termiod.isEnabled`). Verified: `swift
   build` clean; the deploy probe, clone command shape, and daemon absolute-cwd
   all confirmed against real `ukvps`. NOT yet verified (needs live GUI with
   `TERMIO_TERMIOD=1`): the menu clicks, HUD/alert rendering, in-app attach over
   `termiod stdio`, live snapshot repaint.
   Verification caveat worth keeping: driving the bridge from a Python
   `subprocess` pipe is flaky at startup (a harness-side stdin/stdout timing
   race, NOT a bridge bug — direct-socket and bridge both pass 6/6 on hello,
   daemon logs clean); use the Rust integration test, not a Python pipe.
2. **Mac app integration (#170) — IN PROGRESS (M2+M3 landed 2026-08-01,
   `29de132` + `508ace2`).** termio.app is now an opt-in attach client of the
   local daemon (`TERMIO_TERMIOD=1`), the demo's whole point — quit the app,
   the agent keeps running; relaunch, it reattaches with a clean repaint.
   - **M2** (`29de132`): sessions run inside the daemon (attach with
     `create_if_missing`, named by the app session UUID so relaunch rejoins by
     name — same pid); output enters the surface at the same
     `InMemoryTerminalSession.receive` seam the in-process PTY feeds; quit →
     `detach()`, never kill; flag-off path is byte-identical to today. All new
     code in `Sources/termio/Terminal/Termiod/` (`TermiodClient.swift`,
     `TermioStore+Termiod.swift`).
   - **M3** (`508ace2`): attach offers the `snapshot` cap; the `S` frame is
     decoded (`TermiodSnapshot.swift`) and synthesised into a truecolor ANSI
     repaint through the same seam, before live `D` (single serial reader
     preserves order, no hold-back). Replaces M2's ring-replay tear with a
     clean frame; the resize-barrier keyframe repaints idempotently.
     Colors arrive resolved; `attributes` is reserved-zero so bold/underline
     aren't carried yet.
   - **Verified:** `swift build` green; decode+render unit-checked against both
     a hand-built payload and a **real captured daemon S frame** (content +
     ordering). **NOT yet verified live in the GUI** — the prod app wedged on
     the SwiftUI main thread during M2 testing (see [[termio-split-flicker]]);
     the ⌘Q→relaunch demo needs a running app to record.
   - **Remaining for #170:** launchd user-agent plist (so the daemon is up
     before the app and survives reboots) · `Close Session` verb wired to
     `kill` (destroy path) · self-update relaunch story · the live GUI demo
     recording. The `--grid-diff`/scrollback planes stay out of the app until a
     deeper libghostty integration (a byte-stream surface can't inject history
     above the viewport nor consume dirty-row diffs).
3. **QUIC binding (§D.1)** — stays gated on measurement by design. With the
   `G` plane now real, re-measure the three motivating numbers (p95 echo under
   loss, cold-exec latency, roaming) before spending anything here.
4. **Land the branch** — PR #177 is functionally complete and dual-verified;
   promoting it from draft / merging to main is a release-timing call.
5. **Small follow-ups (no product call needed, bundle opportunistically):**
   portable `.cargo/config.toml` (Mac-absolute `ld.lld` path breaks native
   Linux builds — delete/exclude it there; see gotcha in §2 table) ·
   resize-time scrollback restaging (deliberately deferred in 1d) · H/G
   delivery pacing beyond the 4 MiB backlog rule · keyframe cadence tuning
   (256 is a guess).

---

## 7. Open questions for the human (get answers before big dispatches)

1. **Phase 1 scope:** the small 1a slice (snapshot-on-attach + `ready`) first, or a
   larger v1 chunk in one go? (Recommend 1a — smallest end-to-end proof.)
2. **Dev location:** develop Phase 1 **natively on ukvps** (needs the full `termiod`
   crate rsynced there — the user leaned this way), or code on Mac + run/test on
   ukvps? Either way both targets must keep building.
3. **When to open a real (non-draft) PR / merge to main** — the branch has grown
   large; consider whether to land the shipped pieces (#179/#180 + bench + docs)
   before the bigger v1 work.

---

## 8. Pointers

- Issues: #164 (epic), #179 ✅, #180 ✅, #181 (active). Design: the three
  `docs/design/termiod-*.md` files. Bench: `termiod/bench/`.
- Prior art on disk: herdr vendors libghostty-vt at
  `/private/tmp/herdr-inspect/vendor/libghostty-vt/` (build.zig + CMakeLists +
  `include/ghostty/vt.h`); local ghostty checkout at `~/Documents/GitHub/ghostty`.
- The real VT API is `include/ghostty/vt.h` (NOT the app-level `ghostty.h`):
  `ghostty_terminal_new`, `ghostty_terminal_vt_write`, cursor/dims, render-state
  cell iteration, per-row dirty tracking — enough for `S` and `G`.
- User working style (honor it): keep termiod minimal and focused; name mechanisms
  not agents; verify before claiming done; report failures honestly with output;
  don't re-pitch dropped ideas.
