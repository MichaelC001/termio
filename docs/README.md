# termio docs — wiki

How the docs in this folder are organized. GitHub renders this as the landing
page when you browse `docs/`.

## How docs are organized

- Every doc lives **somewhere under `docs/`** and carries its own metadata in
  **YAML front matter** at the top of the file. Subfolders (`design/`,
  `maketing/`, `competitive-analysis/`, …) are just loose grouping — the authoritative
  category is the front matter `type`, **not** the path.
- Each doc declares: `title`, `status`, `type`, `created`/`updated`, and optional
  `related`. The front matter is the **single source of truth** for status —
  there is no separate status file to keep in sync.
- `status` moves down this line over a doc's life:
  `draft → in-review → approved → active → done → archived`.
- `type` is a label: `design` · `rfc` · `marketing` · `research` (add more only
  when a doc genuinely doesn't fit).

To create a new doc or ask "which docs are done / still in draft", use the `doc`
skill (`.claude/skills/doc/`) — it writes the front matter on create and scans it
live on query. Don't hand-maintain doc status anywhere but the doc itself.

## Index

The table below is **generated** from each doc's front matter — it is a derived
view, not a source of truth. The `doc` skill regenerates everything between the
markers; don't edit rows by hand (your edits would be overwritten and could drift
from the real front matter).

<!-- BEGIN docs-index -->
| status | type | title |
| --- | --- | --- |
| active | backlog | [Backlog](backlog/backlog.md) |
| active | bug | [Terminal randomly loses keyboard focus (hollow cursor) after window deactivation](bug/terminal-focus-loss-on-window-key.md) |
| active | design | [iOS terminal input & attachments](design/ios-terminal-input.md) |
| active | marketing | [termio — Go-to-Market & Revenue Reality](maketing/go-to-market.md) |
| active | rfc | [Push-to-talk voice dictation — hold the space bar (iOS shipped, OpenAI)](rfcs/push-to-talk-voice-dictation.md) |
| approved | design | [会话历史 · 搜索 · 恢复（Session History / Search / Resume）](design/session-history-search-resume.md) |
| archived | design | [Sandbox VM —— 原生 per-project 容器（Apple Containerization）](design/sandbox-vm.md) |
| done | research | ["Competitive analysis: Conductor"](competitive-analysis/03-conductor.md) |
| done | research | ["Competitive analysis: Crystal / Nimbalyst"](competitive-analysis/04-crystal.md) |
| done | research | ["Competitive analysis: Unpeel"](competitive-analysis/01-unpeel.md) |
| done | research | ["Competitive analysis: Vibe Island family (status monitors)"](competitive-analysis/07-vibe-island.md) |
| done | research | ["Competitive analysis: Warp (alternative paradigm)"](competitive-analysis/08-warp.md) |
| done | research | ["Competitive analysis: claude-squad"](competitive-analysis/05-claude-squad.md) |
| done | research | ["Competitive analysis: cmux (manaflow-ai)"](competitive-analysis/02-cmux.md) |
| done | research | ["Competitive analysis: container-use (dagger)"](competitive-analysis/06-container-use.md) |
| done | research | ["termio differentiation, gaps, and risks"](competitive-analysis/09-differentiation-and-gaps.md) |
| draft | design | [Vibe Island 式 Agent 状态层（Claude Code hooks）](design/vibe-island-status.md) |
| draft | design | [分享 Agent 会话（带密码的实时分享链接）](design/session-share.md) |
| draft | design | [远程访问与中转策略（tunelo / BYO-tunnel）](design/remote-access-relay-strategy.md) |
| draft | marketing | [OG image & landing copy](maketing/og-image-and-messaging.md) |
| draft | rfc | ["RFC: Per-project agent sandbox (Apple Seatbelt)"](design/sandbox-seatbelt.md) |
| draft | rfc | [Automation — scheduled agent runs](rfcs/automation-scheduled-agent-runs.md) |
| draft | rfc | [Fork libghostty-spm — own the wrapper, rent the engine?](rfcs/fork-libghostty-spm.md) |
| draft | rfc | [Onboarding —— 首次启动体验设计](design/onboarding.md) |
| draft | rfc | [可扩展 Agent —— 配置化定义 + 配置化 Hook](design/agent-extensibility.md) |
| implemented (phase 1) | design | [Worktree information architecture](design/worktree-information-architecture.md) |
| in-review | rfc | [Split panes — Ghostty-style splits in the terminal column](rfcs/split-panes.md) |
| resolved | bug | [iOS terminal fails "unauthorized" while the session list works (companion over tunnel)](bug/companion-terminal-unauthorized-over-tunnel.md) |
<!-- END docs-index -->
