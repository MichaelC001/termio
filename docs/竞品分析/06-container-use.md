# container-use（dagger）

> 最强隔离（容器级）+ "分支即环境"模型；对 termio "小而专、不沙箱"定位**过重**。

## 一句话定位

把每个 Agent 环境建模为「**分支 = 环境，worktree = 文件系统，容器 = 运行时**」，
并通过 MCP 暴露给 Agent 使用。

## 厂商 / 开源 / 链接

- 开源（Dagger 出品）。GitHub：https://github.com/dagger/container-use

## 核心能力

- 每个 Agent 环境 = `container-use/` 远程上的一个分支 + 一个 worktree + 一个容器。
- 每次改动自动提交 → 形成审计轨迹；环境可由 git 历史 + git notes 重建。
- 通过 MCP 让 Agent 创建/操作环境。

## 优势

- 隔离最强（容器级），多 Agent 互不污染主机。
- 自动提交的审计轨迹、可重建性，对"严谨/可回溯"场景有价值。

## 劣势

- 引入 **Docker**，重；与 termio "不沙箱、`.exec` 真 PTY、轻"的定位冲突。

## 与 termio 的异同 / 启示

- 真正值得吸收的只有**一个不变量**：**同一分支绝不在两个 worktree 同时 checkout**——
  termio 的 worktree 逻辑必须守住这条（每会话建新分支，永不附着到别处在用的分支）。
- 容器隔离本身对 termio 是**过度设计**，不应引入。

## 参考链接

- https://github.com/dagger/container-use
- 旁参：devflowinc/uzi（同类 CLI worktree 编排器，又一份命令序列参考）
