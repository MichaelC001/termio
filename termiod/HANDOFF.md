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

Phase 0 (build proof) is done. Phase 1 is wiring the libghostty-vt sidecar into
the daemon. **Recommended smallest verifiable slice first (Phase 1a):**

> A per-session **libghostty-vt sidecar** that consumes the same PTY bytes
> **asynchronously** (fed from the `session.rs` read loop — must NOT gate
> `fan_out`; e.g. a separate task/channel). On a client **attach**, produce one
> **`S` snapshot** of the current screen (cells + cursor + title + authoritative
> `rows`/`cols`) via the FFI, send it **before** live `D` frames, followed by a
> **`ready`** marker. Add the `S` frame kind + a `snapshot` capability in `hello`.
> Keep v0 raw clients valid (capability-gated).
>
> **Acceptance:** attach to a session mid-output → receive a snapshot matching the
> live screen → then live bytes. `smoke_test.py` + `remote_smoke_test.py` stay
> green. `fan_out` still never blocks on the sidecar (anti-100× invariant).

**Then, in order:** resize as a barrier (§C.5: quiesce → resize → fresh `S` →
resume; check `TIOCSWINSZ` failure — §F #11) · `attached` carries `rows`/`cols`
(§C.5, currently omitted) · staged scrollback newest-first after `ready` ·
capability-gated `G` dirty-row diffs (phone-first, §C.6) · then the QUIC binding
(§D.1) only when measured.

**Integration mechanics to decide with the human (see §7):** the FFI crate is a
spike (`spike/vt-ffi`); Phase 1 needs it as a real dependency of the `termiod`
crate, and the `termiod` crate itself must be on the VPS for native dev (rsync it,
like `vt-ffi`, or set up an authed clone). The `build.rs` must build for both
macOS (local host) and aarch64-musl (remote host).

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
