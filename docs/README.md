# termio docs — wiki

How the docs in this folder are organized. GitHub renders this as the landing
page when you browse `docs/`.

## How docs are organized

- Every doc lives **somewhere under `docs/`** and carries its own metadata in
  **YAML front matter** at the top of the file. Subfolders (`design/`,
  `maketing/`, `竞品分析/`, …) are just loose grouping — the authoritative
  category is the front matter `type`, **not** the path.
- Each doc declares: `title`, `status`, `type`, `created`/`updated`, and optional
  `related`. The front matter is the **single source of truth** for status —
  there is no separate status file to keep in sync.
- `status` moves down this line over a doc's life:
  `draft → in-review → approved → active → done → archived`.
- `type` is a label: `design` · `rfc` · `marketing` (add more only when a doc
  genuinely doesn't fit).

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
| active | marketing | [termio — Go-to-Market & Revenue Reality](maketing/go-to-market.md) |
| backlog | design | [会话历史 · 搜索 · 恢复（Session History / Search / Resume）](design/session-history-search-resume.md) |
| draft | design | [Sandbox VM —— 原生 per-project 容器（Apple Containerization）](design/sandbox-vm.md) |
| draft | design | [Vibe Island 式 Agent 状态层（Claude Code hooks）](design/vibe-island-status.md) |
| draft | design | [分享 Agent 会话（带密码的实时分享链接）](design/session-share.md) |
| draft | marketing | [OG image & landing copy](maketing/og-image-and-messaging.md) |
| draft | rfc | [可扩展 Agent —— 配置化定义 + 配置化 Hook](design/agent-extensibility.md) |
| implemented (phase 1) | design | [Worktree information architecture](design/worktree-information-architecture.md) |
<!-- END docs-index -->
