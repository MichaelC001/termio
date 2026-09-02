<div align="center">

<img alt="Termio" src="web/landing/public/logo.png" width="88" />

### The Terminal-first Agentic Development Environment

[![Release](https://img.shields.io/github/v/release/termio-sh/termio?style=flat&logo=github)](https://github.com/termio-sh/termio/releases)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat)](LICENSE)
[![Discord](https://img.shields.io/badge/Discord-555?logo=discord&logoColor=white)](https://discord.gg/H9DKVwsE5f)

<p>English | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.ko.md">한국어</a></p>

[**Download for macOS**](https://downloads.termio.sh/termio.dmg) &nbsp;&bull;&nbsp; [Website](https://termio.sh) &nbsp;&bull;&nbsp; [Docs](https://termio.sh/docs) &nbsp;&bull;&nbsp; [Changelog](https://termio.sh/changelog) &nbsp;&bull;&nbsp; [Discord](https://discord.gg/H9DKVwsE5f)

<img alt="Termio in dark mode: a live Claude Code session next to the project sidebar" src="web/landing/public/screenshots/hero1.png" width="100%" />

</div>

## What it is Terminal-first ADE

When agents write most of the code, the environment's job is to run them and to tell you which one needs you. Termio is that environment, and it's a real terminal because that's where the agents already live.

It wires up each agent's own hooks on first launch. A session reports working, idle, or *needs you* — a dot in the sidebar, a menu-bar tray that rings when one is blocked, the same signal on your phone. Claude Code, Codex, OpenCode, Pi, Amp, Cursor, Copilot, Kimi, Antigravity, Crush, Grok, and any other CLI agent.

The longer argument: [*From IDE to ADE*](docs/essays/from-ide-to-ade.md).

### A tmux alternative

This is the reason people tell you to learn tmux. You don't have to. Every session's shell lives in `termiod`, a daemon, so quitting the app only detaches. Close the laptop, reopen Termio — the agent is where you left it, same process, same scrollback. Only Close Session (⌘W) ends one.

### Remote Terminal

Any Linux VPS you can `ssh` to. Termio reads `~/.ssh/config` and never rewrites it. Settings ▸ Devices ▸ Set Up copies one binary into `~/.local/bin` over SSH, starts the daemon, and installs the agents' hooks there. Local and remote sessions run through the same host. The session lives on the box, not in the connection. Drop the link and the agent keeps working; reattach restores the exact screen.

## Compared with

Termio is the environment the agents run in. The session lives in `termiod` on
the box; the Mac app and the iPhone both attach to it.

| | Termio | [Ghostty](https://ghostty.org) | [cmux](https://cmux.com) | [herdr](https://herdr.dev) | [Superlogical](https://superlogical.com) | [Otty](https://otty.sh) |
| --- | --- | --- | --- | --- | --- | --- |
| Agent Monitor | ✓ hooks | – | ✓ | ✓ | – | ✓ tab badges |
| Agent Orchestration API | ✓ `termio sessions` | – | ✓ CLI + socket API | ✓ socket API | – | – |
| Agent Notification | ✓ menu-bar tray | – | ✓ | ✓ toast, system or sound | – | – |
| Multiplexer | ✓ a daemon owns the PTY | – | restores on relaunch | ✓ a server owns the PTYs | ✓ a server owns the PTYs | restores on relaunch |
| Remote Linux | ✓ Native Supported | – | ✓ SSH workspace | ✓ attach over SSH | ✓ Native Supported | – |
| iOS | ✓ attaches to the host, VPS included | – | ✓ pairs with the Mac | community plugins | announced | – |
| Projects, Workspace | ✓ | – | workspace groups | worktree commands | – | – |
| File tree | ✓ | – | – | ✓ plugin | – | – |
| Editor | ✓ | – | – | – | – | – |
| Diff | ✓ | – | – | ✓ plugin | – | – |
| Open source | ✓ MIT | ✓ MIT | ✓ GPL | ✓ Apache-2.0 | parts, undecided | – |

## Install

**[Download Termio for macOS](https://downloads.termio.sh/termio.dmg)** — free,
no account, macOS 14+. Or with [Homebrew](https://brew.sh):

```sh
brew install --cask termio-sh/tap/termio
```

**On iPhone**: get the companion beta on
[TestFlight](https://testflight.apple.com/join/1Arf1UKR), then pair it by
scanning the QR code in the Mac app's Settings ▸ Mobile.

## What you get

<table>
<tr>
<td width="50%" valign="top">
<h3>Projects hold sessions</h3>
<p>One project per checkout, its terminals and agents underneath. Chats sit above that — scratch agent sessions that don't belong to any project.</p>
<img alt="The Termio sidebar showing Terminals, Chats, projects, worktrees, and their nested sessions" src="web/landing/public/screenshots/docs/04-project-session-hierarchy.png" />
</td>
<td width="50%" valign="top">
<h3>Git worktrees</h3>
<p>One branch per parallel task, created from the sidebar. Worktrees nest under the project they came from.</p>
<img alt="A worktree in the Termio sidebar, with its nested sessions and a context menu to add another" src="web/landing/public/screenshots/docs/12-worktree-hierarchy.png" />
</td>
</tr>
<tr>
<td width="50%" valign="top">
<h3>Split panes</h3>
<p>⌘D splits right, ⇧⌘D splits down. An agent, a dev server, and a shell in one window.</p>
<img alt="Termio with a Codex session grouped beside two shell panes" src="web/landing/public/screenshots/docs/03-grouped-panes.png" />
</td>
<td width="50%" valign="top">
<h3>Status at a glance</h3>
<p>Working, idle, done, or <em>needs you</em> — a mark on every row. The same list is <code>termio sessions list</code>.</p>
<img alt="The Termio sidebar reporting working, done, and needs-you, with termio sessions list in the terminal" src="web/landing/public/screenshots/docs/05-session-statuses.png" />
</td>
</tr>
<tr>
<td width="50%" valign="top">
<h3>File editor</h3>
<p>Click a file in the tree. Syntax highlighting, autosave. The terminal stays the place where you commit.</p>
<img alt="The Termio Files inspector with a Swift file open in the syntax-highlighted editor beside a terminal" src="web/landing/public/screenshots/docs/06-files-editor.png" />
</td>
<td width="50%" valign="top">
<h3>Changes</h3>
<p>A read-only git pane with the current unified diff. Commit, push, and PR stay in the terminal.</p>
<img alt="The Termio Changes tab with a file selected and its red and green unified diff beside the terminal" src="web/landing/public/screenshots/docs/07-changes-diff.png" />
</td>
</tr>
<tr>
<td width="50%" valign="top">
<h3>Search</h3>
<p>Project-wide content search, jumping to the matching line in the editor.</p>
<img alt="The Termio Search tab listing matches for DiffGapText across four files" src="web/landing/public/screenshots/docs/09-project-search.png" />
</td>
<td width="50%" valign="top">
<h3>Command palette</h3>
<p>⌘⇧P. Split, focus, anything you'd hunt a menu for.</p>
<img alt="The Termio command palette open on split, with Split Right selected" src="web/landing/public/screenshots/docs/10-command-palette.png" />
</td>
</tr>
</table>

## Drive it from the terminal

The `termio` CLI drives the running app. An agent inside Termio can spawn a sibling, hand it a task, and read back the reply:

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

`--wait` blocks until the turn settles and comes back with the final status and the transcript range to read. `--json` makes any `sessions` command machine-readable. `--agent` picks which agent `spawn` starts. `--direction` / `--ratio` decide where the new pane lands and how big it is.

```sh
termio sessions spawn "run the migration" --agent codex --wait
```

Session control installs a `termio` [agent skill](https://termio.sh/skill.md) into each agent's skills folder (`~/.claude/skills`, `~/.codex/skills`) and keeps it current on every launch. Any other agent can install the same skill from this repo:

```sh
npx skills add termio-sh/termio --skill termio
```

## On your iPhone

The Termio iOS mirrors every session live — full TUI. A key bar puts esc, tab, ctrl, and arrows above the keyboard, and hold-to-speak transcribes into the prompt. Public beta on [TestFlight](https://testflight.apple.com/join/1Arf1UKR).

<table>
  <tr>
    <td><img alt="Termio on iPhone: the home screen, with Needs You above the projects" src="web/landing/public/screenshots/iphone-home.webp" width="230" /></td>
    <td><img alt="Termio on iPhone: the sessions in a project, each reporting its status" src="web/landing/public/screenshots/iphone-sessions.webp" width="230" /></td>
    <td><img alt="Termio on iPhone: a live agent session with the key bar above the keyboard" src="web/landing/public/screenshots/iphone-session-keys.webp" width="230" /></td>
  </tr>
</table>

## Architecture

Every session lives in `termiod`. Clients only attach. Closing a client does not kill the agent. One protocol; only the pipe changes.

```
  ┌─────────────────┐ unix  ┌────────────┐         ┌─────────────────┐
  │ Mac app         │──────►│            │         │                 │
  ├─────────────────┤ unix  │            │         │                 │
  │ Windows (soon)  │──────►│            │         │                 │
  ├─────────────────┤ wss   │            │         │                 │
  │ iPhone          │──────►│  termiod   │── PTY ─►│  shell / agent  │
  ├─────────────────┤ unix  │   (Mac)    │         │                 │
  │ TUI (soon)      │──────►│            │         │                 │
  ├─────────────────┤ wss   │            │         │                 │
  │ Android (soon)  │──────►│            │         │                 │
  └─────────────────┘       └────────────┘         └─────────────────┘

  ┌─────────────────┐ ssh   ┌────────────┐         ┌─────────────────┐
  │ Mac app         │──────►│            │         │                 │
  ├─────────────────┤ ssh   │            │         │                 │
  │ Windows (soon)  │──────►│            │         │                 │
  ├─────────────────┤ wss   │            │         │                 │
  │ iPhone          │──────►│  termiod   │── PTY ─►│  shell / agent  │
  ├─────────────────┤ ssh   │  (Linux)   │         │                 │
  │ TUI (soon)      │──────►│            │         │                 │
  ├─────────────────┤ wss   │            │         │                 │
  │ Android (soon)  │──────►│            │         │                 │
  └─────────────────┘       └────────────┘         └─────────────────┘
```

The phone attaches to `termiod` on the box, not through the Mac. A session on a VPS is the same object as one on your laptop.

The reasoning is in [`termiod/ARCHITECTURE.md`](termiod/ARCHITECTURE.md).

## Roadmap

- **TUI client** — attach from any terminal, the way you would to tmux.
- **TUI → GUI on mobile** — an optional GUI rendering of agent sessions on the phone, built on top of the live mirror.
- **Android** — the same companion as iPhone.
- **Windows support** — Termio as a native Windows app. Same idea, same termiod core.
- **Web support** — attach to your sessions from any browser, with terminals you can share by link.
- **Issue triage** — GitHub, GitLab, and Linear issues inside the app, ready to hand straight to an agent.

Follow along or weigh in on [GitHub Issues](https://github.com/termio-sh/termio/issues).

## Community

**Termio is looking for long-term maintainers.** If you love using it and would like to own an area of the roadmap above — the web client, Windows, or the iOS companion — join the Discord and say hi, or just pick up an issue.

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
