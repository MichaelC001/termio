<div align="center">

<img alt="Termio" src="web/landing/public/logo.png" width="88" />

### The Terminal-first Agentic Development Environment

[![Release](https://img.shields.io/github/v/release/termio-sh/termio?style=flat&logo=github)](https://github.com/termio-sh/termio/releases)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat)](LICENSE)
[![Discord](https://img.shields.io/badge/Discord-555?logo=discord&logoColor=white)](https://discord.gg/H9DKVwsE5f)

<p>English | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.ko.md">한국어</a></p>

<br />

Run Claude Code, Codex, and any CLI agent side by side in a real Mac terminal —<br />
Swift and libghostty, no Electron. A menu-bar dot tells you which one needs you,<br />
and your iPhone tells you when you're away from the desk.

<br />

[**Download for macOS**](https://downloads.termio.sh/termio.dmg) &nbsp;&bull;&nbsp; [Website](https://termio.sh) &nbsp;&bull;&nbsp; [Docs](https://termio.sh/docs) &nbsp;&bull;&nbsp; [Changelog](https://termio.sh/changelog) &nbsp;&bull;&nbsp; [Discord](https://discord.gg/H9DKVwsE5f)

<br />

<img alt="Termio in dark mode: a live Claude Code session next to the project sidebar" src="web/landing/public/screenshots/hero1.png" width="100%" />

</div>

## Install

**[Download Termio for macOS](https://downloads.termio.sh/termio.dmg)** — free,
no account, macOS 14+. Or with [Homebrew](https://brew.sh):

```sh
brew install --cask termio-sh/tap/termio
```

**On iPhone**: get the companion beta on
[TestFlight](https://testflight.apple.com/join/1Arf1UKR), then pair it by
scanning the QR code in the Mac app's Settings ▸ Mobile.

## Built for agentic coding and engineering

The IDE was built around a person typing code. When agents write most of the
code, the environment's job changes: it's where agents work and where you
direct, review, and unblock them. Termio is that environment — Terminal-first,
because that's where the agents already live — built for the new
shape of the work: several agents going at once, most of them fine without
you, one of them stuck. (The longer argument:
[*From IDE to ADE*](docs/essays/from-ide-to-ade.md).)

- **A real terminal, not a web view.** Swift + AppKit on
  [libghostty](https://ghostty.org) (Ghostty's terminal core), rendered with
  Metal. No Electron, no xterm.js.
- **Projects → sessions.** The sidebar mirrors how you actually work: each
  project holds its terminals and agents, with git worktrees nested beneath it
  for parallel tasks.
- **Status with zero setup.** Termio wires up each agent's own hooks and reads
  the signals agents already emit. Working, idle, or *needs you* — per-session
  dots, and a menu-bar tray that stays calm, pulses while agents work, and
  rings when one is blocked on you.
- **Review without leaving.** A read-only git pane (changes, history, unified
  diffs), a file tree with a click-to-edit editor, and project-wide content
  search — the terminal stays the place where you commit.
- **Git worktrees.** Create one from the sidebar; it nests under the project,
  one branch per parallel task.
- **Chats.** Scratch agent sessions that don't belong to any project.
- **Usage meters.** Claude and Codex plan limits, read locally in
  Settings → Usage.
- **Themes.** Light, dark, and a glass appearance that follows the system.
- **Auto-update.** Notarized DMG, updated by Sparkle.
- **Free.** No account, no license keys, no paid tier. MIT-licensed.

## Works with your agents

Claude Code, Codex, Antigravity, Grok, Cursor Agent, Copilot, Amp, OpenCode,
Pi, Kimi — and any other CLI agent, because a session is just a real terminal.
For the built-in agents, Termio installs each one's own hook or plugin
automatically, so status detection works the first time you launch them.

## Drive it from the terminal

Termio ships a `termio` CLI, so sessions are scriptable — including by the
agents themselves. An agent running inside Termio can spawn a sibling, hand it
a task, and read back the reply:

```sh
termio sessions list                       # who's working, idle, or waiting on you
termio sessions spawn "fix the flaky test" # start a new agent session on a prompt
termio sessions send ab12cd34 "1"          # answer a sibling's permission prompt
termio sessions watch                      # stream status changes as they happen
```

Agents learn this themselves: Session control installs a `termio`
[agent skill](https://termio.sh/skill.md) into each agent's skills folder
(`~/.claude/skills`, `~/.codex/skills`) and keeps it current on every launch.
Any other agent can install the same skill straight from this repo:

```sh
npx skills add termio-sh/termio --skill termio
```

## On your iPhone

The companion app mirrors every Mac session live on your phone — the full
TUI, not a chat summary. A key bar puts esc, tab, ctrl, and arrows above the
keyboard, and hold-to-speak transcribes straight into the prompt. Free, in
public beta: [join on TestFlight](https://testflight.apple.com/join/1Arf1UKR).

## Architecture

Termio is moving every session onto `termiod`, a small Rust daemon that owns the
PTY on whichever machine the work runs on. Each UI — the Mac app, the phone, a
browser — is a client that attaches to it over one versioned protocol.

```
  web     ─WSS──┐
  iPhone  ─WSS──┼─► termiod (Mac)    ─► PTY ─► shell / agent
  Mac app ─unix─┘

  web     ─WSS──┐
  iPhone  ─WSS──┼─► termiod (Linux)  ─► PTY ─► shell / agent
  Mac app ─ssh──┘
```

Only the pipe changes; the frames are identical on every leg. No client reaches
a session through another client, which is what stops the phone from being a
satellite of the Mac — and what makes a session on a VPS the same object as one
on your laptop.

**Built:** the daemon and its protocol, the `unix` and `ssh` transports,
snapshot-on-attach, scrollback, and the file and git planes — running behind a
flag while the Mac app moves onto it. **Not built:** the WSS transport the
browser and the phone need.

The reasoning is in [`termiod/ARCHITECTURE.md`](termiod/ARCHITECTURE.md) and the
design notes under [`docs/`](docs/README.md).

## Roadmap

- **Linux remote server** — run sessions on a Linux machine you own — a VPS, a
  devbox — supervised from the Mac app.
- **Mux server** — a durable session host: the session lives on the box, not in
  the connection. Shut the laptop and the agent keeps working; reattach and the
  exact screen comes back.
- **Issue triage** — GitHub, GitLab, and Linear issues inside the app, ready to
  hand straight to an agent.
- **TUI → GUI on mobile** — an optional GUI rendering of agent sessions on the
  phone, built on top of the live mirror.
- **Windows support** — Termio as a native Windows app. Same idea, same
  terminal core, no Electron.
- **Web support** — attach to your sessions from any browser, with terminals
  you can share by link.

Follow along or weigh in on [GitHub Issues](https://github.com/termio-sh/termio/issues).

## Community

**Termio is looking for long-term maintainers.** If you love using it and
would like to own an area of the roadmap above — the Linux remote server, the
web client, Windows, or the iOS companion — join the Discord and say hi, or
just pick up an issue.

- **[Discord](https://discord.gg/H9DKVwsE5f)** — chat with the developer and other users
- **[GitHub Issues](https://github.com/termio-sh/termio/issues)** — bugs and feature requests

## Contributors

<a href="https://github.com/termio-sh/termio/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=termio-sh/termio" alt="Contributors" />
</a>

## License

[MIT](LICENSE).
