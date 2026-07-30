# termiod — durable session host

> **A session lives in a host. Viewers only attach.**  
> **Composable** · **Direct.** Local is remote to localhost. Detach ≠ kill.

`termiod` is termio’s **session host**. Composable parts (host · protocol · clients · pipes). Direct path (client → host → PTY). The CLI is a **reference client**, not the architecture.

Full model: [`ARCHITECTURE.md`](ARCHITECTURE.md) · design: `docs/design/termiod-session-mux.md` · epic [#164](https://github.com/jiweiyuan/termio/issues/164) · POC [#170](https://github.com/jiweiyuan/termio/issues/170)–[#172](https://github.com/jiweiyuan/termio/issues/172) · draft PR [#177](https://github.com/jiweiyuan/termio/pull/177).

```
  clients (Mac / iOS / CLI)          host (termiod)
         │                                │
         │   Session Protocol             │ owns PTYs
         ├──── Unix socket (local) ──────►│
         └──── SSH pipe (remote) ────────►│──► shell / agent
```

## Build

```sh
cd termiod
cargo build            # ./target/debug/termiod
cargo build --release
```

One binary = **host** (`serve`) + **clients** (`attach`, `list`, …) + **SSH transport helpers** (`remote …`).

## Host (local)

```sh
termiod serve          # foreground host (usually auto-started)
```

Socket: `$XDG_RUNTIME_DIR/termiod/termiod.sock`, else `/tmp/termiod-<uid>/termiod.sock`  
(`0700` dir, `0600` socket). Override: `TERMIOD_SOCK`.

## Clients (local)

```sh
termiod attach demo                    # create-on-missing; Ctrl-\ detaches
termiod attach build -- npm run dev
termiod list
termiod list --json
termiod create --name api --cwd ~/proj -- bash
termiod send api "npm test"            # inject without attach
termiod kill api
```

Multi-client: several `attach` to the same session — output fans out; **newest client is the writer**; newest size wins resize.

## Protocol v0

Framed stream: `[kind:u8][len:u32 BE][payload]`

| kind | payload | meaning |
| --- | --- | --- |
| `C` | JSON | control: create / list / kill / send / attach / detach |
| `D` | raw bytes | PTY I/O (hot path) |
| `R` | `rows:u16, cols:u16` | resize (TIOCSWINSZ) |

Later: host-side vt snapshot / diffs (not in this POC). No panes inside the host (zmx lesson).

## Remote (SSH is a pipe)

Transport is **system OpenSSH** only — no public listener. The **host still runs on the VPS**; SSH only reaches it.

```sh
termiod remote deploy my-vps           # cross-compile musl → ~/.local/bin/termiod
termiod remote list my-vps
termiod remote attach my-vps demo -- bash
termiod remote open my-vps --cwd '~/proj' --agent shell
```

`my-vps` = `~/.ssh/config` alias. Close the laptop; reattach — agent kept running on the VPS. See [`DEPLOY.md`](DEPLOY.md).

## Test

```sh
cargo build
python3 smoke_test.py          # #170 — 16 local host checks
python3 remote_smoke_test.py   # #171/#172 — 8 checks via fake-ssh
```

## Layout

| path | part |
| --- | --- |
| `src/daemon.rs` · `session.rs` · `pty.rs` | **Host** |
| `src/protocol.rs` | **Protocol** |
| `src/client.rs` · `main.rs` | **Reference client** |
| `src/remote.rs` | **SSH transport** helpers |
| `ARCHITECTURE.md` | Clean model |
