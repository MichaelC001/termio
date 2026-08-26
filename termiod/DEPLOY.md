# Deploying termiod to a Linux VPS (over SSH)

termiod runs remotely with **no custom network stack**: the transport is your
own OpenSSH, and SSH is also the access-control boundary. The remote daemon
listens on a **Unix socket only** — never `0.0.0.0`. This covers issues
**#171** (deploy + remote attach) and **#172** (`remote open`).

Clients that cannot speak SSH — a phone, a browser — reach the box through an
opt-in **loopback** WebSocket instead, described under
["Serving a phone or a browser"](#serving-a-phone-or-a-browser-opt-in). It is
off unless you turn it on, and it never binds a public address.

## Hands-on: test the remote terminal from a Mac, step by step

Everything below assumes an SSH alias in `~/.ssh/config` (the examples use
`ukvps`) and the toolchain from "Cross-compiling on the Mac" below.

```sh
# 1. Build the CLI on the Mac (from the repo's termiod/ directory)
export PATH=$HOME/.local/share/termiod-toolchains/zig-0.16.0:$PATH
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
cargo build
alias tio=./target/debug/termiod

# 2. Deploy to the VPS. Two gotchas: a RUNNING daemon keeps executing the old
#    binary image (and scp onto a running binary fails with ETXTBSY), so stop
#    it first. Existing sessions die with it — this is a dev-loop step.
ssh ukvps pkill -x termiod || true
tio remote deploy ukvps

# 3. Open a durable session and attach (creates + attaches in one command;
#    --agent claude/codex launches an agent instead of a shell)
tio remote open ukvps --name demo

# 4. Inside the session: start something long-lived, e.g. `top`.
#    Detach with Ctrl-\  (the session KEEPS RUNNING on the VPS).
#    Simulate a real drop instead: close the laptop lid or kill Wi-Fi —
#    a dead SSH connection is also just a detach, never a kill.

# 5. Proof of survival — same pid before and after:
tio remote list ukvps

# 6. Reattach. v1 bootstrap kicks in: one S snapshot repaints the CURRENT
#    screen (top, mid-run, no replayed escape torrent), `ready`, then live
#    bytes; scrollback is staged behind it (the CLI prints
#    "scrollback: N rows staged" when you detach).
tio remote attach ukvps demo

# 7. Second read-only viewer (scripting/piping — no tty, no input):
tio remote attach ukvps demo --observe | head -50

# 8. Done? End the session for real:
ssh ukvps '~/.local/bin/termiod kill demo'
```

What you are testing at each step: durable host (4–5), snapshot-on-attach
(6, Phase 1a), staged scrollback (6, Phase 1d), single-writer + observer
plane (7, #179). The resize barrier (1b) fires whenever you resize your
terminal while attached as the writer — observers repaint from a fresh
snapshot instead of parsing at the wrong width. The `grid_diff` plane (1e)
has no remote CLI flag yet (`attach --grid-diff` is local-only today); it
rides the same framed protocol, so it lights up remotely once `termiod stdio`
lands (see the protocol doc's roadmap).

## The one-liner

```sh
termiod remote open my-vps            # deploy if needed, create a session, attach
```

`my-vps` is any `~/.ssh/config` alias (or `user@host`). Behind that:

1. `ssh my-vps test -x ~/.local/bin/termiod` — installed? If not, deploy.
2. `ssh my-vps termiod create …` — create a durable session; capture its id.
3. `ssh -t my-vps termiod attach <id>` — attach over an SSH PTY.

Close your laptop mid-session; the daemon on the VPS owns the PTY, so the agent
keeps running. Reconnect with `termiod remote attach my-vps <id>` (or `open`).

## Cross-compiling on the Mac

Since v1 the crate embeds **libghostty-vt** (the `termiod/vt` crate), which is
built by **Zig 0.16.0** via `build.rs` — Zig doubles as the C cross-compiler,
so the output is still a single **static musl** Linux binary and no
`musl-gcc`/Docker is needed. Rust-side cross-linking uses the `rust-lld` that
ships with the toolchain, wired in `.cargo/config.toml` (checked in; it names
`rust-lld` rather than a path, so it resolves from whatever toolchain is active
and is fine to keep when building natively on Linux). Required environment on
the Mac:

```sh
# On PATH, under that exact name: `libghostty-vt-sys` invokes `zig` by name and
# honours no `ZIG` override.
export PATH=$HOME/.local/share/termiod-toolchains/zig-0.16.0:$PATH
export DEVELOPER_DIR=/Library/Developer/CommandLineTools   # avoids Xcode 26's arm64e-only SDK
```

One-time target install:

```sh
rustup target add aarch64-unknown-linux-musl   # ARM VPS (Graviton, Ampere, Pi)
rustup target add x86_64-unknown-linux-musl     # Intel/AMD VPS
```

`termiod remote deploy <host>` runs `uname -m` on the host, picks the matching
target, cross-compiles, and installs. Manual build:

```sh
cargo build --release --target x86_64-unknown-linux-musl
file target/x86_64-unknown-linux-musl/release/termiod
# → ELF 64-bit, statically linked  (runs on any glibc/musl Linux of that arch)
```

If you'd rather use a real musl cross-toolchain (e.g. for C deps later),
install one and override `linker` in `.cargo/config.toml`, or build on the host
and deploy the prebuilt binary:

```sh
termiod remote deploy my-vps --bin path/to/linux/termiod
```

## What deploy does

```sh
termiod remote deploy my-vps
#  ssh  my-vps mkdir -p ~/.local/bin
#  scp  <built binary>  my-vps:.local/bin/termiod
#  ssh  my-vps chmod +x ~/.local/bin/termiod
#  ssh  my-vps ~/.local/bin/termiod --version      # verify
```

Install path is `~/.local/bin/termiod`. Override with `TERMIOD_REMOTE_BIN`
(e.g. `/usr/local/bin/termiod`) on the client for both deploy and attach.

Make sure `~/.local/bin` is on the remote `PATH` if you want to run `termiod`
bare over SSH; the `remote` subcommands always call the absolute path, so this
is only for your own convenience.

## Starting the daemon: on-demand (default)

No service required. The daemon **auto-starts, detached (`setsid`), on the
first client op** (`attach`/`list`/`create`). Because it's in its own session,
it survives the SSH channel closing — that's the whole durability trick.

### Optional: a user systemd unit

If you want the daemon always up (so `list` is instant and sessions predate any
attach), drop a `--user` unit on the host:

```ini
# ~/.config/systemd/user/termiod.service
[Unit]
Description=termiod session host
[Service]
ExecStart=%h/.local/bin/termiod serve
Restart=on-failure
[Install]
WantedBy=default.target
```

```sh
ssh my-vps loginctl enable-linger $USER   # keep it running after you log out
ssh my-vps systemctl --user enable --now termiod
```

This is strictly optional; on-demand start is the supported default.

## Serving a phone or a browser (opt-in)

A phone cannot open a Unix socket and a browser cannot run SSH, so `termiod`
has one opt-in TCP listener: a WebSocket that carries the same framed protocol,
onto the same socket, with a pairing token in front. Nothing about the SSH path
changes, and a daemon with no WSS bind behaves exactly as it does above.

```sh
ssh my-vps ~/.local/bin/termiod pair              # mint the token; prints it
ssh my-vps ~/.local/bin/termiod serve --wss 127.0.0.1:8790 \
      --wss-origin https://box.tailnet.ts.net
```

**The bind is loopback only.** `--wss` parses its value as an IP address and
refuses anything for which `is_loopback()` is false — `0.0.0.0`, `[::]`,
`192.168.1.10`, and a hostname that resolves off loopback are all rejected when
the flag is parsed, before the daemon starts. Put TLS in front of it:

```sh
tailscale serve --bg --https=443 --set-path=/termio http://127.0.0.1:8790
```

termiod never terminates TLS, ships a CA, or pins a certificate. Tailscale
Serve and Caddy are the security team we didn't hire. Serve does not strip its
mount path, so requests arrive as `/termio/ws`; termiod accepts both `/ws` and
`/termio/ws` as the same Upgrade, which is why no rewrite rule is needed. Caddy
users who prefer `handle_path /termio/*` (which does strip) need no flag change
either.

The default port is **8790** — not the Mac companion's 8787 / 8788, so a Mac
running both does not have them fight.

### The token

`termiod pair` mints 24 random bytes as base64url and stores them `0600` at
`pair.token`, beside `host.id`. `--wss` never mints one: a listener that cannot
authenticate is not something to start by accident.

| Command | What it does |
| --- | --- |
| `termiod pair` | Print the token, minting it on first run. |
| `termiod pair --json` | The invite as JSON: `url`, `token`, `host_id`, `proto`. |
| `termiod pair --qr` | The invite as a QR code, drawn in this terminal. |
| `termiod pair --rotate` | Replace the token. Attached clients detach; no session dies. |
| `termiod pair --wss-off` | Delete `wss.bind`. The next start is Unix-only. |

`--json` and `--qr` need a reachable URL, and the daemon cannot derive one: the
listener binds loopback on purpose, so the public name lives in `--wss-origin`
or in the tunnel. Both refuse and say so when it is unset rather than print an
invite that points nowhere. Pass `--url https://box.tailnet.ts.net/termio/` for
a proxy mounted under a path.

**What the QR costs you: whoever photographs it has full access to the daemon
until you rotate the token.** It is the long-lived pairing secret, not a
short-lived enrollment code, and `termiod pair --rotate` is the only revocation
there is. Do not screenshare or record a terminal you have just printed one in;
if you do, rotate.

### The durable unit

A flag that lives only on one foreground argv dies on the next crash restart —
the daemon auto-starts as bare `termiod serve`. So an explicit `--wss` with a
token in place writes `wss.bind` (`0600`) beside the socket, and the unit sets
`TERMIOD_WSS` as well. Either one alone is enough; the pair is what survives
both a restart and a client-triggered autostart.

```ini
# ~/.config/systemd/user/termiod.service
[Unit]
Description=termiod session host
[Service]
ExecStart=%h/.local/bin/termiod serve --wss 127.0.0.1:8790 --wss-origin https://box.tailnet.ts.net
Environment=TERMIOD_WSS=127.0.0.1:8790
Environment=TERMIOD_WSS_ORIGIN=https://box.tailnet.ts.net
Restart=on-failure
[Install]
WantedBy=default.target
```

```sh
ssh my-vps loginctl enable-linger $USER
ssh my-vps systemctl --user enable --now termiod
```

The bind is resolved in this order, first valid loopback address winning:
`--wss`, then `TERMIOD_WSS`, then `wss.bind`. With none of the three there is no
TCP listener at all.

Missing `pair.token` splits by where the bind came from:

- **`--wss` on this process's argv** — refuse the whole start, write nothing,
  and say `run termiod pair`. The operator asked for a listener that cannot
  authenticate.
- **Inherited from `TERMIOD_WSS` or `wss.bind`** — bind the Unix socket, skip
  TCP, log `wss skipped: no pair.token`. A restart must never take the daemon's
  own socket down.

## Reconnect workflow

```sh
termiod remote list my-vps               # what's running on the VPS
termiod remote attach my-vps <id|name>   # reattach; Ctrl-\ detaches
termiod remote attach my-vps build -- npm run dev   # attach-or-create by name
```

Session survives: SSH disconnects, laptop sleep, network drops. It ends only on
`kill` or when its process exits.

## Security model

| Concern | Position |
| --- | --- |
| Listener | Unix socket under `$XDG_RUNTIME_DIR/termiod/` (or uid-tmp), mode 0600. **No public port.** The opt-in WebSocket binds loopback and nothing else; TLS and reachability are the proxy's job. |
| Auth / ACL | **SSH.** Whoever can `ssh my-vps` as your user can reach your daemon — same trust as a shell. Over the WebSocket it is the `pair.token`, and anyone holding it has the same access. |
| Credentials | Your ssh-agent / `~/.ssh` keys. termiod stores and transmits none. `pair.token` is the one secret it writes, `0600`, and it never leaves the box except in an invite you hand out. |
| Multi-user | Socket is per-uid and 0600; another user on the box can't connect. A user who can read `pair.token` can, which is why it is `0600` beside the socket. |
| Transport crypto | Entirely SSH's, or entirely the front proxy's. termiod adds no crypto and no bespoke protocol on the wire beyond the framed session stream inside the channel. |
| Browser CSRF | An `Origin` allowlist (`--wss-origin`), defaulting to same-origin. It constrains pages; the token is what authenticates the pipe. There is no exemption for clients that "look native". |
| Revocation | `termiod pair --rotate`. It drops every attached WebSocket and refuses the old secret from then on. Sessions keep running — a rotation is a detach, not a kill. |

Do **not** expose the Unix socket over TCP (e.g. `socat`) without adding your
own authentication — the daemon assumes socket access already means "trusted
as this user."

## Testing without a VPS

`remote_smoke_test.py` runs the real `remote` subcommands against the local
binary through a fake-`ssh` shim (drops `-t`/`-o`, runs the command locally),
proving the orchestration and that a session survives "disconnect". Real
cross-arch install needs an actual Linux host; the steps above are the manual
path.
