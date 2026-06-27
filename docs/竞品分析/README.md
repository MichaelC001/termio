# termio 竞品分析

> 版本：2026-06-27 ｜ 对应 termio 进度：Milestone 1–5（项目/会话侧栏、PTY 持久化、
> Agent 预设、状态 + 菜单栏托盘、5 页设置、每会话 git worktree）

本目录每个产品一份独立文档。阅读顺序按「与 termio 的直接竞争强度」排列。

## 目录

| # | 产品 | 一句话 | 与 termio 关系 |
| --- | --- | --- | --- |
| [01](01-unpeel.md) | **Unpeel** | 原生 Mac 终端 + Sessions MCP，termio 的对标原型 | 直接对标（设计原型） |
| [02](02-cmux.md) | **cmux**（manaflow-ai） | 原生 Swift+libghostty 终端，YC 出品、23k★ | **最直接竞品（同基底）** |
| [03](03-conductor.md) | Conductor | Mac 原生，worktree 并行 + App 内评审 | 相反哲学（重 diff） |
| [04](04-crystal.md) | Crystal / Nimbalyst | Electron，多会话 + 最佳 merge-back UX | 参考（worktree/合并） |
| [05](05-claude-squad.md) | claude-squad | Go TUI，tmux + worktree | 参考（git plumbing） |
| [06](06-container-use.md) | container-use | 容器隔离 + 分支即环境 | 过重（隔离思路参考） |
| [07](07-vibe-island.md) | Vibe Island 系 | 刘海/托盘状态监控 | 状态检测方法论来源 |
| [08](08-warp.md) | Warp | AI 原生通用终端 | 替代范式 |

> 另有「替代范式」：Cursor / VS Code + 扩展（IDE 内建 Agent，重 diff，与 termio 相反）、
> Ghostty / WezTerm / iTerm2（termio 的**基底**而非对手）、纯 tmux 手搓（DIY 基线）。

## termio 当前能力快照

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| 原生 libghostty 终端 | ✅ | `.exec` 真 PTY，Metal 渲染，非 Electron |
| 项目 → 会话侧栏 | ✅ | 会话按项目分组，会话树持久化（重启后侧栏还在） |
| 会话存活（SurfaceCache） | ✅ | 切换会话不杀 shell；**退出 App 后 PTY 不保留** |
| Agent 预设 | ✅ | Terminal / Claude Code / Codex / OpenCode / Pi，带品牌 logo |
| 会话状态（忙/完成/需要你） | ✅ | 侧栏状态点 + 菜单栏托盘脉冲/响铃，零配置 |
| 实时标题（OSC title） | ✅ | Agent 用标题描述当前动作 |
| 5 页设置，实时生效 | ✅ | appearance / interface / terminal / agents / worktrees |
| 每会话 git worktree | ✅ | 会话在独立 worktree 编辑分支 |
| **Sessions MCP（跨会话编排）** | ❌ | 让一个 Agent 读/驱动另一个会话 |
| **永不消亡的会话宿主** | ❌ | 退出窗口后 Agent 继续跑、重连回放 |
| **逐轮 working（hooks 层）** | 🟡 | 现仅零配置 bell/通知，缺连续"思考中" |

## 横向能力对比矩阵

| 能力 | termio | cmux | Unpeel | Conductor | Crystal | claude-squad |
| --- | :-: | :-: | :-: | :-: | :-: | :-: |
| 原生（非 Electron） | ✅ | ✅ | ✅ | ✅ | ❌ | ➖TUI |
| libghostty 终端核 | ✅ | ✅ | ✅ | ? | ❌ | ❌ |
| 多 Agent 会话盘 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 状态可视化（忙/需要你） | ✅ | ✅ | ✅ | 🟡 | 🟡 | 🟡 |
| **菜单栏脉冲托盘** | ✅ | ❌(pane ring) | ✅ | ? | ❌ | ❌ |
| **App 自动管 worktree** | ✅ | 🟡(仅模式) | ✅ | ✅ | ✅ | ✅ |
| Sessions MCP / Agent 互驱 | ❌ | 🟡(socket API) | ✅ | ❌ | ❌ | 🟡 |
| 退出后会话不死 | ❌ | 🟡(恢复) | ✅ | ? | ❌ | ✅(tmux) |
| diff / 代码评审面板 | ⛔刻意不做 | ⛔无 | ⛔刻意不做 | ✅ | ✅ | ❌ |
| 本地优先 / 无账号 | ✅ | ✅ | ✅ | ? | ✅ | ✅ |
| 开源 | ❌私有 | ✅GPL | ❌闭源 | ❌ | ✅ | ✅ |

> 图例：✅ 有 ｜ 🟡 部分 ｜ ❌ 无 ｜ ⛔ 刻意不做 ｜ ➖ 形态不同 ｜ ? 未证实

## 结论（先行）

termio 与对标 **Unpeel** 的真正差距只剩两项：**Sessions MCP** 与 **never-die 宿主**。
但真正的市场威胁是 **cmux**——同样原生 + libghostty + 本地优先 + 状态可视化 + 不做 diff，
且已被 YC、23k★ 验证了整个品类。termio 不可能在"广度/声量"上赢 cmux，
**唯一可守的护城河是「极简而有主见」：把 项目→会话→worktree 流程做成一等自动化，
菜单栏托盘做成环境氛围常驻**——这正是 cmux（sprawling primitive，无菜单栏托盘、
worktree 仅为推荐模式）和 Conductor/Crystal（重 diff）都没占住的位置。坚持
「小而专、不做代码面板、本地优先」是 termio 区别于所有竞品的根本立场。

详见各产品文档与 [09-差异化与缺口.md](09-差异化与缺口.md)。
