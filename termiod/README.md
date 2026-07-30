# termiod — durable PTY session host (Rust POC)

A minimal **session multiplexer** for termio: `termiod` owns PTYs so a session
outlives every viewer. Quit your client, the shell/agent keeps running; attach
again and it's still there. **Detach ≠ kill.**

This is the Rust language spike for termio issue **#164** and implements
children **#170** (local durable host), **#171** (SSH deploy + remote attach),
and **#172** (`remote open`). Design source of truth:
`docs/design/termiod-session-mux.md` and `docs/design/session-daemon-architecture.md`.

Scope is deliberately narrow (the zmx lesson): **session persistence only.** No
panes/windows inside the daemon, no VT/grid snapshot — the hot path is **raw PTY
bytes over a socket**. A libghostty-vt snapshot layer is a later phase, out of
scope here.

## Build

```sh
cd termiod
cargo build            # debug → ./target/debug/termiod
cargo build --release  # optimized, small static-ish binary
```

One binary is both the daemon and the client.

## Use (local)

```sh
# Attach to a session named "demo", creating it (login shell) if missing.
# The daemon auto-starts on first use. Detach with Ctrl-\  (session lives on).
termiod attach demo

# Run a specific program instead of the login shell:
termiod attach build -- npm run dev

# From another terminal — a second viewer of the same session:
termiod attach demo          # multi-client fan-out; newest attach is the writer

termiod list                 # what's running
termiod list --json
termiod create --name api --cwd ~/proj -- bash   # create without attaching
termiod send api "npm test"  # inject a command without attaching (adds Enter)
termiod kill api             # end a session + its process group
```

Socket location: `$XDG_RUNTIME_DIR/termiod/termiod.sock`, else
`/tmp/termiod-<uid>/termiod.sock` (dir is 0700, socket 0600). Override with
`TERMIOD_SOCK` to run isolated daemons.

## Protocol v0

One framed, bidirectional stream. A frame is `[kind:u8][len:u32 BE][payload]`:

| kind | payload | meaning |
| --- | --- | --- |
| `C` | JSON | control: `create` / `list` / `kill` / `send` / `attach` / `detach` / responses |
| `D` | raw bytes | PTY output (daemon→client) and input (client→daemon) — the hot path |
| `R` | `rows:u16, cols:u16` | window resize (TIOCSWINSZ), newest-client claim |

Rules: detach never kills; output fans out to all attached clients; input has a
single writer (the newest attach); the newest client's size wins. On (re)attach
the daemon replays a recent-output ring buffer so you see the current screen.

## Remote over SSH (#171 / #172)

Transport is **system OpenSSH only** — no custom crypto, no public listener.
SSH is the transport *and* the ACL. The daemon auto-starts (detached via
`setsid`) on the remote's first client op, so a session survives SSH
disconnect for free.

```sh
# Cross-compile for the host's arch and install to ~/.local/bin/termiod:
termiod remote deploy my-vps
#   …or hand it a prebuilt Linux binary instead of cross-compiling:
termiod remote deploy my-vps --bin target/x86_64-unknown-linux-musl/release/termiod

termiod remote list my-vps                     # sessions on the VPS
termiod remote attach my-vps demo -- bash      # attach/create over ssh -t

# One-shot (#172): ensure deployed → create durable session → attach:
termiod remote open my-vps --cwd '~/proj' --agent shell
```

`<host>` is any `~/.ssh/config` alias (or `user@host`); keys stay in your
ssh-agent. Close your laptop, reconnect, `remote attach` again — the agent
kept running on the VPS. No tmux/zellij on the host.

See [`DEPLOY.md`](DEPLOY.md) for cross-compile setup, an optional systemd
`--user` unit, and the security model.

## Test

```sh
cargo build
python3 smoke_test.py        # 16 checks, exits non-zero on any failure
```

The smoke test drives real PTYs and asserts the #170 contract end-to-end:
attach → type → detach → **session survives** → reattach sees the same process;
multi-client fan-out; single-writer input; newest-client resize;
inject-without-attach; kill.

## Layout

| file | role |
| --- | --- |
| `src/protocol.rs` | frame + control-message wire format |
| `src/pty.rs` | open PTY, spawn with the `login_tty` shape, async read/write |
| `src/session.rs` | one durable session actor (fan-out, ring buffer, writer arbitration) |
| `src/daemon.rs` | session table + Unix-socket accept loop |
| `src/client.rs` | connect/auto-start + raw-mode interactive attach |
| `src/remote.rs` | SSH deploy + remote attach/open |
| `src/main.rs` | CLI |
