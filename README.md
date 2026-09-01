<div align="center">

<img alt="Termio" src="web/landing/public/logo.png" width="88" />

### The Terminal-first Agentic Development Environment

[![Release](https://img.shields.io/github/v/release/termio-sh/termio?style=flat&logo=github)](https://github.com/termio-sh/termio/releases)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat)](LICENSE)
[![Discord](https://img.shields.io/badge/Discord-555?logo=discord&logoColor=white)](https://discord.gg/H9DKVwsE5f)

<p>English | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.ko.md">한국어</a></p>

<br />

Four agents running. Three are fine. One has been sitting on a permission<br />
prompt for ten minutes and nothing on your screen says which.

<br />

Termio runs them all in one real Mac terminal and tells you which one needs you.<br />
A dot per session, a menu-bar tray that rings when an agent is blocked, and the<br />
same signal on your iPhone when you're away from the desk.

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

## The IDE was built around a person typing

When agents write most of the code, the environment's job changes. It stops
being where you type and becomes where agents work and where you direct,
review, and unblock them. That is a different shape of work: several agents
going at once, most of them fine without you, one of them stuck.

Termio is built for that shape, and it's terminal-first because that's where
the agents already live. (The longer argument:
[*From IDE to ADE*](docs/essays/from-ide-to-ade.md).)

## Your agents keep running when you close the laptop

Every session's shell lives in `termiod`, a daemon, so quitting the app only
detaches. Go to lunch, shut the lid, reopen Termio — the agent is where you
left it, same process, same scrollback. Only Close Session (⌘W) ends one.

This is the reason people tell you to learn tmux. You don't have to. Everything
else tmux would have taught you is already a Mac shortcut:

- **Splits are ⌘D**, zoom is ⇧⌘↩. No Ctrl-b prefix first. tmux needs a prefix
  because it has to disambiguate itself from the program in the pane; a ⌘
  shortcut never reaches that program, so nothing collides with vim or a TUI.
- **Scroll, select, copy** with the trackpad and ⌘C. There is no copy-mode to
  enter and leave.
- **A session on a Linux box** runs on the same daemon, and
  `termiod attach <session>` reaches it from any shell.
- **Scripting** is `termio sessions` (below), which does what `send-keys`
  scripts do — and agent status is a protocol object, not a pane to scrape.

## You always know which agent needs you

Termio wires up each agent's own hooks on first launch and reads the signals
agents already emit. No config file, no prompt markers to install.

The result is a status per session — working, idle, or *needs you* — shown as a
dot in the sidebar and summed up in a menu-bar tray that stays calm, pulses
while agents work, and rings when one is blocked on you. Click the ring and
you're in the session that raised it. When you're away from the Mac, the same
status arrives on your phone.

## Everything you'd otherwise leave the terminal for

- **A real terminal, not a web view.** Swift + AppKit on
  [libghostty](https://ghostty.org) (Ghostty's terminal core), rendered with
  Metal. No Electron, no xterm.js.
- **Projects hold sessions.** The sidebar mirrors how you actually work: one
  project per checkout, its terminals and agents underneath, git worktrees
  nested below that — one branch per parallel task, created from the sidebar.
- **Review without switching apps.** A read-only git pane with changes,
  history, and unified diffs; a file tree with a click-to-edit editor; and
  project-wide content search. The terminal stays the place where you commit.
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
termio .                                    # open the current directory as a project
termio sessions list                        # who's working, idle, or waiting on you
termio sessions spawn "fix the flaky test"  # start a new agent session on a prompt
termio sessions run "pnpm test --watch"     # start a plain terminal session on a command
termio sessions send ab12cd34 "1"           # answer a sibling's permission prompt
termio sessions read ab12cd34 --lines 40    # print what's on a session's screen
termio sessions watch                       # stream status changes as they happen
termio sessions focus ab12cd34              # bring a session forward in the app
termio sessions close ab12cd34              # close it
termio notify "the migration finished"      # post a macOS notification
```

Flags carry the rest: `--wait` blocks until the turn settles and comes back with
the final status and the transcript range to read, `--json` makes any `sessions`
command machine-readable, `--agent` picks which agent `spawn` starts, and
`--direction` / `--ratio` decide where the new pane lands and how big it is.

```sh
termio sessions spawn "run the migration" --agent codex --wait
```

Agents learn this themselves: Session control installs a `termio`
[agent skill](https://termio.sh/skill.md) into each agent's skills folder
(`~/.claude/skills`, `~/.codex/skills`) and keeps it current on every launch.
Any other agent can install the same skill straight from this repo:

```sh
npx skills add termio-sh/termio --skill termio
```

## On your iPhone

The companion app mirrors every Mac session live on your phone — the full TUI,
not a chat summary. An agent that blocks while you're out is one you can answer
without going back to the desk. A key bar puts esc, tab, ctrl, and arrows above
the keyboard, and hold-to-speak transcribes straight into the prompt. Free, in public beta:
[join on TestFlight](https://testflight.apple.com/join/1Arf1UKR).

<table>
  <tr>
    <td><img alt="Termio on iPhone: the home screen, with Needs You above the projects" src="web/landing/public/screenshots/iphone-home.webp" width="230" /></td>
    <td><img alt="Termio on iPhone: the sessions in a project, each reporting its status" src="web/landing/public/screenshots/iphone-sessions.webp" width="230" /></td>
    <td><img alt="Termio on iPhone: a live agent session with the key bar above the keyboard" src="web/landing/public/screenshots/iphone-session-keys.webp" width="230" /></td>
  </tr>
</table>

## Architecture

Every Termio session runs on `termiod`, a small Rust daemon that owns the
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

**Built:** the daemon and its protocol; the `unix`, `ssh`, and `wss`
transports; snapshot-on-attach; scrollback; the file and git planes; and
launchd/systemd supervision. The Mac app runs every session through it, and the
phone attaches to a Mac or a Linux box over WSS. **Not built:** the browser
client.

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
- **WeChat group** — Chinese-speaking users, scan the QR code below
- **[GitHub Issues](https://github.com/termio-sh/termio/issues)** — bugs and feature requests

<img alt="WeChat group QR code" src="web/landing/public/wechat-group.png" width="220" />

The WeChat code expires every few days. If it has, ask in Discord and it gets refreshed.

## Contributors

<a href="https://github.com/termio-sh/termio/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=termio-sh/termio" alt="Contributors" />
</a>

## License

[MIT](LICENSE).
