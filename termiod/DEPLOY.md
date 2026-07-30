# Deploying termiod to a Linux VPS (over SSH)

termiod runs remotely with **no custom network stack**: the transport is your
own OpenSSH, and SSH is also the access-control boundary. The remote daemon
listens on a **Unix socket only** — never a TCP port, never `0.0.0.0`. This
covers issues **#171** (deploy + remote attach) and **#172** (`remote open`).

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

## Cross-compiling on the Mac (no external toolchain)

The crate is pure-Rust (only `libc` FFI, no C to compile), so it cross-links to
a **static musl** Linux binary using the `rust-lld` that ships with every Rust
toolchain — **no `musl-gcc`, no Docker, no zig**. That wiring lives in
`.cargo/config.toml` (checked in). One-time target install:

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
| Listener | Unix socket under `$XDG_RUNTIME_DIR/termiod/` (or uid-tmp), mode 0600. **No TCP, no public port.** |
| Auth / ACL | **SSH.** Whoever can `ssh my-vps` as your user can reach your daemon — same trust as a shell. |
| Credentials | Your ssh-agent / `~/.ssh` keys. termiod stores and transmits none. |
| Multi-user | Socket is per-uid and 0600; another user on the box can't connect. |
| Transport crypto | Entirely SSH's. termiod adds no crypto and no bespoke protocol on the wire beyond the framed session stream inside the SSH channel. |

Do **not** expose the Unix socket over TCP (e.g. `socat`) without adding your
own authentication — the daemon assumes socket access already means "trusted
as this user."

## Testing without a VPS

`remote_smoke_test.py` runs the real `remote` subcommands against the local
binary through a fake-`ssh` shim (drops `-t`/`-o`, runs the command locally),
proving the orchestration and that a session survives "disconnect". Real
cross-arch install needs an actual Linux host; the steps above are the manual
path.
