---
name: termio
description: See and drive the sibling agent sessions running alongside you on this machine via the `termio server` CLI — list them and their status, start a new agent or plain-terminal session, send a prompt or an answer into one, and set your own status. Use when delegating work to another session, or checking on what other sessions are doing. Do not use merely because a task could run in parallel. Requires running inside a termiod session (TERMIOD_SESSION_ID set).
---

# Driving sibling sessions (termio server)

If `TERMIOD_SESSION_ID` is not set in your environment, you are not running
inside a termiod session — say so and stop instead of trying to drive sessions
you cannot see.

You are running inside a session hosted by `termiod` on this machine, alongside
other sessions on the same host. Coordinate with them through the `termio`
CLI's `server` commands. The installed CLI is the authority on syntax: where
this text and `termio server --help` disagree, trust the CLI.

**Sessions here are scoped to this machine, not to a project.** The daemon lists
every session it hosts, so read the names and working directories before acting
on one — there is no project filter to lean on.

- `termio server list --json` — every session on this host, with its status
  (`working` / `idle` / `needs_you` / `done` / `failed` / `unknown`), name, and
  pid. Sessions are addressed by id or by name; both work everywhere a target
  is taken.
- `termio server send <target> "<text>"` — type into a session as if the user had.
  Use it to answer a sibling that is blocked on a question. `--no-enter` types
  the text without pressing Enter.
- `termio server create --name <name> --cwd <dir> -- <program> [args…]` — start a new
  session and print its id. With no `--` argv it starts a login shell.
- `termio server kill <target>` — kill a session and its process group.
- `termio agent report <state>` — report your own state. Valid states are
  `working`, `attention` (you need the user), `done`, and `idle`.

## When to use this

- **Delegating.** A task that is genuinely separate work — a long build, an
  independent investigation — can go to a new session so the user watches it in
  its own pane.
- **Supervising.** Before reporting that something is done, check whether a
  sibling you started is still `working` or has gone `needs_you`.
- **Unblocking.** A sibling sitting at `needs_you` is waiting on a human. If you
  can answer it from what you already know, `send` the answer.

Do not spawn a session merely because two things *could* happen at once. A
session the user did not ask for and does not watch is noise.

## What is not available here

Unlike the same skill on a Mac running the termio app, there is **no** transcript
reader and **no** project-scoped listing: `termiod` hosts sessions, and the
project a session belongs to is not yet readable back from it. Do not guess at a
sibling's conversation contents — ask it with `send`, or read what the user
tells you.
