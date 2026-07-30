# termiod architecture

> **A session lives in a host. Viewers only attach.**  
> **Composable** · **Direct.**

| | Composable | Direct |
| --- | --- | --- |
| | Host · protocol · clients · pipes plug independently | One hop: client → protocol → host → PTY |
| | Any client, any pipe, any host | No second session owner, no nested WM, no invented crypto |

Local is remote to localhost. Design: `docs/design/termiod-session-mux.md`.

## Three parts

```
   CLIENTS                         PROTOCOL                      HOST
   (stateless)                     (versioned)                   (authority)
┌──────────────┐              ┌─────────────────┐          ┌──────────────┐
│ termio.app   │──┐           │ attach / detach │          │   termiod    │
│ TermioMobile │  │  transport│ create / list   │  always  │ session table│
│ CLI (ref)    │──┼──────────►│ I/O · resize    │─────────►│ owns PTYs    │
│ (web later)  │  │  (pipe)   │ status · roster │          │ (later: vt)  │
└──────────────┘──┘           └─────────────────┘          └──────┬───────┘
                                                                  │
                                                                  ▼
                                                         shell / agent
```

| Part | What it is | What it is not |
| --- | --- | --- |
| **Host** | Long-lived process on a machine; owns every session PTY | A public TCP service; a window manager |
| **Protocol** | Framed control + terminal bytes (v0); later snapshots/diffs | Tied to SSH or Unix sockets |
| **Clients** | Viewers that attach/detach | Owners of process lifetime |

**Transport** is not a fourth product. It is how protocol bytes move:

| Pipe | Use |
| --- | --- |
| Unix socket | Host on this machine |
| System SSH | Host on a VPS / devbox (auth + crypto for free) |
| WSS / relay | Phone / hostile networks (optional) |

## Hard rules

1. **Host ≠ viewer** — closing every client leaves sessions alive.  
2. **PTY only on the host** — clients never allocate the agent’s TTY.  
3. **SSH is a pipe** — never `ssh -tt host claude` as the product path.  
4. **No nested WM** — tabs/splits belong to the OS / native app (zmx).  
5. **No invented crypto** — build host + protocol only.

## Vocabulary

| Say | Don’t say |
| --- | --- |
| host / daemon / `termiod` | “the CLI tool” (as the architecture) |
| attach client | “the SSH session” (for our session object) |
| transport / pipe | “remote mode that owns the agent” |

The shipped binary is host **and** a reference CLI client (tmux/zmx packaging). That does not change the model: **`termiod serve` is the product core; `attach` is a client.**

## Data path (v0 POC)

```
client ──► pipe ──► termiod ──► PTY ──► agent
                │
                └── fan-out to other clients
                └── ring replay on reattach
```

- Hot path: raw PTY bytes over the pipe.  
- VT / libghostty snapshot: **later** (host-side sidecar for resync), not in the critical path for every keystroke.

## Remote

```
Mac client ── ssh ──► Linux termiod ── PTY ──► agent
```

Same protocol as local. Daemon on the VPS auto-starts (or runs under systemd `--user`). SSH disconnect detaches the client; it does not kill the session.

## Map to source

| Module | Part |
| --- | --- |
| `daemon.rs` · `session.rs` · `pty.rs` | Host |
| `protocol.rs` | Protocol |
| `client.rs` · CLI in `main.rs` | Reference client |
| `remote.rs` | Transport helper (SSH deploy / stdio bridge) |
| `paths.rs` | Socket location |

## Three-step product sequence

1. **Incredible host** — durable multi-session runtime (**direct**).  
2. **Composable agent surface** — status, worktrees, tools as real protocol clients (**composable**).  
3. **Multi-device operable** — Mac/iOS, discovery, optional relay — still direct pipes, no required cloud.

Superlogical: *mux → composable → production*. We keep **composable** and insist on **direct**.
