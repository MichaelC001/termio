# cmux（manaflow-ai）

> **termio 单一最直接竞品**：同样原生 Swift + libghostty + 本地优先 + 状态可视化 + 不做 diff。
> 但开源、YC 出品、~23,000★，已替整个品类做了市场验证。

## 消歧（"cmux" 撞名严重）

1. **manaflow-ai/cmux（cmux.com）** —— 本文对象。原生 macOS libghostty 终端，
   为并行跑 AI 编码 Agent 而生。
2. **Manaflow 早期 cmux（cmux.sh）** —— 同公司**前代产品**：云/Docker 容器 + VS Code
   workspace 的 Agent 管理器，带 git diff viewer。公司已**转向**原生终端。
   ⚠️ "在隔离云容器里跑 Agent + diff 查看器"是**老架构**的事，别和现旗舰混淆。
3. **craigsc/cmux** —— 无关的纯 Bash CLI，"tmux for Claude Code"，~574★。
4. （`soheilhy/cmux` 是 Go 连接复用库，完全无关。）

下文均指 **#1**。

## 一句话定位

"为编码 Agent 而生的开源终端"——原生 macOS、基于 Ghostty，可把多个 Agent 以
**原生 pane/split/tab** 并行跑在一处，强调**可编程**与**多任务**。

## 厂商 / 开源 / 链接

- 厂商：**Manaflow**（YC **S24**，"开源应用 AI 实验室"）；创始人 Lawrence Chen、Austin Wang。
- 开源：**是**，**GPL-3.0-or-later**（部分材料称 AGPL），另售**商业授权**。
- GitHub：https://github.com/manaflow-ai/cmux —— **~23k★ / ~1.8k forks**，48+ releases。
  2026-02 前后发布，两周内涨到 ~17k★，HN 第 2，Ghostty 作者 Mitchell Hashimoto 背书。
- 站点：https://cmux.com

## 技术栈与形态

- **原生 macOS，Swift + AppKit，基于 libghostty**（用库，非 fork），GPU 加速；**非 Electron**。
- 分发：DMG + **Sparkle 自动更新**、**Homebrew cask**（`brew install --cask cmux`）、nightly。
  **不上 Mac App Store**（GPL/Sparkle 不兼容）。
- **本地优先、终端本身无需账号**，直接读你已有的 `~/.config/ghostty/config`。
- 平台：当前**仅 macOS**；Linux 公测、Windows 候补、另有 **iOS 伴侣 App**（实时同步）。

## 核心能力

- **并行 Agent 会话**：每个 Agent 跑在原生 **pane/split/tab**（而非隐藏后台进程）；
  **竖向标签侧栏**显示每个 tab 的 git 分支、工作目录、活跃端口、关联 PR 号/状态。
- **Agent 无关**：凡能在终端跑的都支持——Claude Code、Codex、OpenCode、Gemini CLI、
  Kiro、Aider、Goose、Amp、Cline、Cursor Agent、Grok；并对 **Claude Code Teams** 和
  **oh-my-opencode** 多模型编排做了特殊集成（子 Agent 渲染成真 pane）。
- **状态可视化（招牌「Notification Rings」）**：当某 pane 的 Agent 在等输入时，**pane 边框亮蓝环**；
  外加侧栏未读 badge、通知 popover、macOS 桌面通知。靠终端转义序列（OSC 9/99/777）或 cmux CLI 触发。
  设计目标是**不轮询地盯住 5–10 个并发被阻塞的 Agent**。
- **git worktree**：推荐"每 worktree 配一个 tab"做 per-PR 隔离——但**worktree 生命周期并非
  App 核心深度自动化**，更多是侧栏分支/PR 元数据呈现的**推荐模式**（第三方文章常夸大成"全自动")。
- **不做 diff/评审**：原生终端**仅对话/终端**，侧栏给分支+PR 号但**无内建 diff 面板**
  （diff viewer 在老的云产品里）。
- **轻量跨 Agent 编排**：**CLI + Unix socket API** 可创建 workspace、控制 pane、注入按键、
  **派生其它 Agent**；Agent 还能驱动**内嵌可脚本浏览器**（读 AX 树、点击、填表、跑 JS）。
  定位是"可组合原语"，非 MCP 式受控编排。
- 会话恢复（窗口/pane/scrollback）；SSH 远程 workspace；无终端 Web UI（老云产品才有）。

## 优势

- 原生 Swift/libghostty，快、无 Electron 包袱。
- **巨大且迅猛的声量与背书**（23k★、Hashimoto、YC）——已替品类验证需求。
- 真·Agent 无关；Notification Rings 是"哪个 Agent 卡住了"的有效答案。
- 可编程：socket API + 内嵌可脚本浏览器 + 派生 Agent 的 CLI。

## 劣势

- 仅 macOS（Linux 公测、Windows 候补），覆盖窄。
- 终端内**无 diff/评审**，要切到 GitHub/编辑器。
- **worktree 是"模式"而非一等自动化 UX**；**无菜单栏托盘**模型。
- 拷贝左（GPL/AGPL）+ 商业授权会劝退部分采用方。
- 表面积大（浏览器 pane、SSH、socket API、iOS、Teams）——"可组合原语"=不够有主见/引导。
- 产品身份漂移（云容器管理器 → 原生终端）易混淆定位。

## 与 termio 的异同 / 启示

- **收敛点**：都是原生 macOS、本地优先、状态指示侧栏、**不做 diff**、面向 worktree。
  你的状态点 ≈ cmux 的 notification rings/badges；你的项目→会话侧栏 ≈ cmux 的竖向 tabs。
  **termio 在做的，正是 cmux 已验证的品类。**
- **termio 刻意更窄更干净**：**项目→会话层级 + 菜单栏托盘** + **App 一等自动化的本地 worktree**，
  表面积小而有主见。cmux 更"全家桶"：内嵌浏览器、SSH、socket 自动化、Claude Teams、
  多模型编排、iOS、外加云/Docker 沙箱血统——优化的是"可编程 + 多 pane"。
- **可守的角度**：termio = **有主见的极简 + 一等 worktree 自动化 + 菜单栏氛围常驻**；
  这恰是 cmux 的两个空档（无深度 worktree 生命周期、无菜单栏托盘，diff 在被弱化的另一个云产品里）。
- **不可硬碰的地方**：广度、声量、社区、可编程表面——别在这些维度跟 cmux 比拼。

## 参考链接

- Repo：https://github.com/manaflow-ai/cmux ｜ 站点：https://cmux.com
- YC Launch：https://www.ycombinator.com/launches/PbB-cmux-the-open-source-terminal-built-for-coding-agents
- 技术深读：https://www.oflight.co.jp/en/columns/cmux-manaflow-ai-agent-terminal-2026
- 老云产品（cmux.sh）背景：https://www.scriptbyai.com/coding-agents-parallel-manaflow/
