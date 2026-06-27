# claude-squad（smtg-ai）

> worktree git plumbing 的**权威可照搬参考**；TUI 形态、无原生 GUI 质感。

## 一句话定位

Go 写的 TUI，用 **tmux + git worktree** 并行管理多个 Claude / Codex / Aider 会话。

## 厂商 / 开源 / 链接

- 开源。GitHub：https://github.com/smtg-ai/claude-squad
- 技术栈：Go，TUI；底层 tmux（会话存活）+ git worktree（隔离）。

## 核心能力

- 每会话独立 worktree（放在**仓库外**：`<config>/worktrees/<sanitized-branch>_<纳秒时间戳>`），
  独立分支前缀；从 `HEAD` 的 SHA 建新分支，确保干净起点。
- push 动作（commit + push 分支）；清理链 `worktree remove -f → branch -D → prune`，
  对预存在分支不删除。
- 因 tmux：**退出后会话仍在**（reattach）。

## 优势

- **git plumbing 干净、可直接照搬**（termio 的 worktree 命令序列就以它为蓝本）。
- 纯终端、跨平台、开源；tmux 带来天然的 never-die。

## 劣势

- TUI 而非原生 GUI；状态可视化、品牌质感远不如 termio/cmux/Unpeel。
- 表达力受限于终端 UI。

## 与 termio 的异同 / 启示

- **直接参考价值最高的 git 部分**：分支前缀 + "是否预存在"标志的清理策略，能避免误删用户分支；
  worktree 目录命名加时间戳保唯一。
- 它用 tmux 实现 never-die——给 termio 的 never-die 宿主提供了一个"最朴素可行"的思路对照
  （另见 zmx/dtach，见 [09](09-差异化与缺口.md)）。
- termio 的优势在于把这些 CLI 能力包进**原生、有状态盘、有托盘**的 GUI。

## 参考链接

- https://github.com/smtg-ai/claude-squad
